//
//  ArtifactSource.swift
//  WikiViewerKit
//
//  Transport abstraction. A source only moves bytes; it never decides
//  whether they are trustworthy. Validation (size, SHA-256, SQLite checks)
//  happens in ArtifactUpdater / AssetProvider regardless of the source.
//

import Foundation
import WikiShared

public protocol ArtifactSource: Sendable {
    var displayName: String { get }
    /// Stable identity of the publication lineage (e.g. folder or base URL).
    /// Generation numbers are only compared within one lineage.
    var identifier: String { get }
    /// Reads `manifest.json` (at most `ArtifactManifest.maximumEncodedSize` bytes).
    func fetchManifest() async throws -> Data
    /// Copies a published file (`generations/…` or `assets/…`) to
    /// `destination`, failing if it is larger than `maximumBytes`.
    func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case unsafePath(String)
    case notFound(String)
    case tooLarge(String)
    case http(Int)
    case unavailable(String)

    public var description: String {
        switch self {
        case .unsafePath(let p): "Refusing unsafe path \(p)"
        case .notFound(let p): "\(p) not found at the source"
        case .tooLarge(let p): "\(p) is larger than announced"
        case .http(let code): "HTTP status \(code)"
        case .unavailable(let m): m
        }
    }
}

/// Paths a source may be asked for. Everything else is rejected before any
/// I/O happens.
enum PublishedPath {
    static func validate(_ relativePath: String) throws {
        guard VaultPath.isSafeRelative(relativePath) else { throw TransportError.unsafePath(relativePath) }
        let ok = relativePath == "manifest.json"
            || relativePath.hasPrefix("generations/viewer-")
            || relativePath.hasPrefix("assets/")
            || relativePath.hasPrefix("chunks/")
        guard ok, !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw TransportError.unsafePath(relativePath)
        }
    }
}

/// Copies `source` to `destination` in chunks, enforcing a size limit.
func boundedCopy(from source: URL, to destination: URL, maximumBytes: Int64, name: String) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var total: Int64 = 0
    while true {
        try Task.checkCancellation()
        // Each read's buffer is released per iteration (FileHandle returns
        // autoreleased data on Darwin).
        let done: Bool = try autoreleasepool {
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
            total += Int64(chunk.count)
            if total > maximumBytes { throw TransportError.tooLarge(name) }
            try output.write(contentsOf: chunk)
            return false
        }
        if done { break }
    }
    try output.synchronize()
}

// MARK: - Local folder (development, Files app, iCloud Drive)

/// Reads a publish directory from the local file system. With a
/// security-scoped bookmark this works for any folder the user picked in the
/// Files app — including an iCloud Drive folder the Mac mini publishes into —
/// without iCloud entitlements.
///
/// Reads are coordinated with NSFileCoordinator so File Provider items
/// (e.g. iCloud Drive placeholders) are materialized before copying. The
/// folder is only ever read; nothing is opened in place.
public struct LocalFolderArtifactSource: ArtifactSource {
    public let root: URL
    public let securityScoped: Bool

    public init(root: URL, securityScoped: Bool = false) {
        self.root = root
        self.securityScoped = securityScoped
    }

    public var displayName: String { root.lastPathComponent }
    public var identifier: String { "folder:" + root.standardizedFileURL.path }

    public func fetchManifest() async throws -> Data {
        let source = self
        return try await withAccess {
            try source.coordinatedRead("manifest.json") { url in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: ArtifactManifest.maximumEncodedSize + 1) ?? Data()
                guard data.count <= ArtifactManifest.maximumEncodedSize else { throw TransportError.tooLarge("manifest.json") }
                return data
            }
        }
    }

    public func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        try PublishedPath.validate(relativePath)
        let source = self
        try await withAccess {
            try source.coordinatedRead(relativePath) { url in
                try boundedCopy(from: url, to: destination, maximumBytes: maximumBytes, name: relativePath)
            }
        }
    }

    /// Coordinated reads can block for a long time (e.g. while iCloud Drive
    /// downloads a file), so they run on a dedicated dispatch queue instead
    /// of occupying a thread of Swift's cooperative pool.
    static let ioQueue = DispatchQueue(label: "wikiviewer.folder-source", qos: .utility, attributes: .concurrent)

    /// Cancelling the calling task resumes it immediately with
    /// `CancellationError` even if the coordinated read is still blocked
    /// (e.g. an iCloud placeholder while offline); the blocked read finishes
    /// or fails later on its own queue and its result is dropped.
    func withAccess<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let root = root
        let securityScoped = securityScoped
        let once = ResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                Self.ioQueue.async {
                    let granted = securityScoped ? root.startAccessingSecurityScopedResource() : false
                    defer { if granted { root.stopAccessingSecurityScopedResource() } }
                    once.resume(with: Result { try body() })
                }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }

    func coordinatedRead<T>(_ relativePath: String, _ body: (URL) throws -> T) throws -> T {
        let url = root.appendingPathComponent(relativePath)
        var coordinationError: NSError?
        var result: Result<T, any Error> = .failure(TransportError.notFound(relativePath))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            guard FileManager.default.fileExists(atPath: readURL.path) else {
                result = .failure(TransportError.notFound(relativePath))
                return
            }
            result = Result { try body(readURL) }
        }
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == NSFileReadNoSuchFileError {
                throw TransportError.notFound(relativePath)
            }
            throw coordinationError
        }
        return try result.get()
    }
}

// MARK: - HTTP(S)

/// Fetches a publish directory served over HTTP(S), e.g. by
/// `wikiindex serve` behind an HTTPS reverse proxy or a VPN.
public struct HTTPArtifactSource: ArtifactSource {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var displayName: String { baseURL.host() ?? baseURL.absoluteString }
    public var identifier: String { "http:" + baseURL.absoluteString }

    func url(for relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }

    public func fetchManifest() async throws -> Data {
        var request = URLRequest(url: url(for: "manifest.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, "manifest.json")
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ArtifactManifest.maximumEncodedSize { throw TransportError.tooLarge("manifest.json") }
        }
        return data
    }

    public func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        try PublishedPath.validate(relativePath)
        var request = URLRequest(url: url(for: relativePath))
        request.timeoutInterval = 120
        try await BoundedDownload.run(request: request, configuration: session.configuration, destination: destination, maximumBytes: maximumBytes, name: relativePath)
    }

    static func check(_ response: URLResponse, _ path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw TransportError.notFound(path) }
        guard (200..<300).contains(http.statusCode) else { throw TransportError.http(http.statusCode) }
    }
}

import Synchronization

/// Streams an HTTP response body to a file, cancelling as soon as it exceeds
/// `maximumBytes`, so a misbehaving server cannot fill the device's disk.
final class BoundedDownload: NSObject, URLSessionDataDelegate, Sendable {
    struct State {
        var handle: FileHandle?
        var total: Int64 = 0
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
    }

    let state = Mutex(State())
    let maximumBytes: Int64
    let destination: URL
    let name: String

    init(maximumBytes: Int64, destination: URL, name: String) {
        self.maximumBytes = maximumBytes
        self.destination = destination
        self.name = name
    }

    static func run(request: URLRequest, configuration: URLSessionConfiguration, destination: URL, maximumBytes: Int64, name: String) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        let delegate = BoundedDownload(maximumBytes: maximumBytes, destination: destination, name: name)
        delegate.state.withLock { $0.handle = handle }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            try HTTPArtifactSource.check(response, name)
            if response.expectedContentLength > maximumBytes { throw TransportError.tooLarge(name) }
            completionHandler(.allow)
        } catch {
            state.withLock { $0.failure = error }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = state.withLock { state -> Bool in
            guard state.failure == nil else { return true }
            state.total += Int64(data.count)
            if state.total > maximumBytes {
                state.failure = TransportError.tooLarge(name)
                return true
            }
            do {
                try state.handle?.write(contentsOf: data)
            } catch {
                state.failure = error
                return true
            }
            return false
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            try? state.handle?.synchronize()
            try? state.handle?.close()
            state.handle = nil
            let c = state.continuation
            state.continuation = nil
            return (c, state.failure ?? error)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}

/// Resumes a continuation at most once (first of: result, cancellation).
final class ResumeGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var pending: Result<T, any Error>?
        var done = false
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let pending: Result<T, any Error>? = state.withLock { s in
            if let p = s.pending { s.done = true; s.pending = nil; return p }
            s.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { s in
            guard !s.done else { return nil }
            guard let c = s.continuation else {
                if s.pending == nil { s.pending = result }
                return nil
            }
            s.done = true
            s.continuation = nil
            return c
        }
        continuation?.resume(with: result)
    }
}
