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
    /// Returns the manifest once it may name a generation newer than
    /// `generation`: immediately when the source can be notified (HTTP long
    /// poll against `wikiindex serve`), otherwise after about `interval`.
    /// Callers compare the generation themselves; nothing is guaranteed to
    /// have changed.
    func waitForManifest(after generation: Int64, interval: Duration) async throws -> Data

    /// Whether `submitRequest` can work at all (false for the bundled demo).
    var acceptsRequests: Bool { get }
    /// Puts an encoded `HostRequest` in the Mac's queue. Idempotent: the
    /// same id may be sent again after an uncertain failure.
    func submitRequest(_ data: Data, id: UUID) async throws
    /// Reads a request's status file, or throws `TransportError.notFound`
    /// while the Mac has not picked the request up yet.
    func fetchRequestStatus(id: UUID) async throws -> HostRequestStatus
    /// Reads the skills the Mac offers (`requests/skills.json`), or throws
    /// `TransportError.notFound` when it offers none.
    func fetchSkillCatalog() async throws -> SkillCatalog
}

extension ArtifactSource {
    public func waitForManifest(after generation: Int64, interval: Duration) async throws -> Data {
        try await Task.sleep(for: interval)
        return try await fetchManifest()
    }

    public var acceptsRequests: Bool { false }

    public func submitRequest(_ data: Data, id: UUID) async throws {
        throw TransportError.unavailable("This source does not accept requests")
    }

    public func fetchRequestStatus(id: UUID) async throws -> HostRequestStatus {
        throw TransportError.notFound(HostRequestStatus.publishedPath(for: id))
    }

    public func fetchSkillCatalog() async throws -> SkillCatalog {
        throw TransportError.notFound(SkillCatalog.publishedPath)
    }
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
            || relativePath.hasPrefix("packs/")
            || relativePath.hasPrefix("requests/")
        guard ok, !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw TransportError.unsafePath(relativePath)
        }
    }
}

/// Copies `source` to `destination` in chunks, enforcing a size limit.
/// `isCancelled` reports cancellation of a caller that is no longer waiting
/// (the copy runs on a dispatch queue, outside the task): the copy then stops
/// and removes what it wrote, so it cannot refill a directory being cleaned up.
func boundedCopy(from source: URL, to destination: URL, maximumBytes: Int64, name: String, isCancelled: () -> Bool = { false }) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    if isCancelled() { throw CancellationError() }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var total: Int64 = 0
    while true {
        if isCancelled() {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
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
    public let acceptsRequests: Bool

    /// Requests are written to `<root>/inbox/`, the only place the app ever
    /// writes in the folder. Pass `acceptsRequests: false` for a folder no
    /// Mac reads requests from (the bundled demo).
    public init(root: URL, securityScoped: Bool = false, acceptsRequests: Bool = true) {
        self.root = root
        self.securityScoped = securityScoped
        self.acceptsRequests = acceptsRequests
    }

    public static let inboxFolder = "inbox"

    public var displayName: String { root.lastPathComponent }
    public var identifier: String { "folder:" + root.standardizedFileURL.path }

    public func fetchManifest() async throws -> Data {
        let source = self
        return try await withAccess { _ in
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
        try await withAccess { isCancelled in
            try source.coordinatedRead(relativePath) { url in
                try boundedCopy(from: url, to: destination, maximumBytes: maximumBytes, name: relativePath, isCancelled: isCancelled)
            }
        }
    }

    public func submitRequest(_ data: Data, id: UUID) async throws {
        guard acceptsRequests else { throw TransportError.unavailable("This source does not accept requests") }
        guard data.count <= HostRequest.maximumEncodedSize else { throw TransportError.tooLarge("request") }
        let root = root
        try await withAccess { _ in
            let inbox = root.appendingPathComponent(Self.inboxFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let file = inbox.appendingPathComponent(HostRequest.fileName(for: id))
            var coordinationError: NSError?
            var writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [.forReplacing], error: &coordinationError) { url in
                // Atomic: the Mac never sees half a request.
                do { try data.write(to: url, options: [.atomic]) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileWriteVolumeReadOnlyError {
                    throw TransportError.unavailable("This app may not write to the folder. Choose it again in Settings to allow requests.")
                }
                throw error
            }
        }
    }

    public func fetchRequestStatus(id: UUID) async throws -> HostRequestStatus {
        try HostRequestStatus.decode(try await readSmallFile(HostRequestStatus.publishedPath(for: id), maximumBytes: HostRequestStatus.maximumEncodedSize))
    }

    public func fetchSkillCatalog() async throws -> SkillCatalog {
        guard acceptsRequests else { throw TransportError.notFound(SkillCatalog.publishedPath) }
        return try SkillCatalog.decode(try await readSmallFile(SkillCatalog.publishedPath, maximumBytes: SkillCatalog.maximumEncodedSize))
    }

    /// Reads at most `maximumBytes + 1` bytes of a published file; the
    /// decoder rejects anything longer.
    func readSmallFile(_ path: String, maximumBytes: Int) async throws -> Data {
        let source = self
        return try await withAccess { _ in
            try source.coordinatedRead(path) { url in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: maximumBytes + 1) ?? Data()
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
    /// `body` receives a check for that cancellation, so long work can stop.
    func withAccess<T: Sendable>(_ body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let root = root
        let securityScoped = securityScoped
        let once = ResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                Self.ioQueue.async {
                    let granted = securityScoped ? root.startAccessingSecurityScopedResource() : false
                    defer { if granted { root.stopAccessingSecurityScopedResource() } }
                    once.resume(with: Result { try body { once.isFinished } })
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
///
/// Every request goes through one URLSession, so the many small requests of
/// a chunk transfer reuse connections (and TLS sessions) instead of paying a
/// handshake each; per-request size limits are enforced by a task delegate.
public struct HTTPArtifactSource: ArtifactSource {
    public let baseURL: URL
    let session: URLSession
    /// Bearer token `wikiindex serve --token-file` expects for requests.
    let requestToken: String?

    public init(baseURL: URL, requestToken: String? = nil, session: URLSession = HTTPArtifactSource.sharedSession) {
        self.baseURL = baseURL
        self.requestToken = requestToken
        self.session = session
    }

    public var acceptsRequests: Bool { true }

    public func submitRequest(_ data: Data, id: UUID) async throws {
        guard data.count <= HostRequest.maximumEncodedSize else { throw TransportError.tooLarge("request") }
        var request = URLRequest(url: url(for: "requests"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let requestToken, !requestToken.isEmpty {
            request.setValue("Bearer " + requestToken, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.upload(for: request, from: data)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: return
            case 401, 403: throw TransportError.unavailable("The Mac refused the request: check the request token in Settings")
            case 404, 405: throw TransportError.unavailable("The server does not accept requests (wikiindex serve --token-file)")
            default: throw TransportError.http(http.statusCode)
            }
        }
    }

    public func fetchRequestStatus(id: UUID) async throws -> HostRequestStatus {
        try HostRequestStatus.decode(try await fetchSmallFile(HostRequestStatus.publishedPath(for: id), maximumBytes: HostRequestStatus.maximumEncodedSize))
    }

    public func fetchSkillCatalog() async throws -> SkillCatalog {
        try SkillCatalog.decode(try await fetchSmallFile(SkillCatalog.publishedPath, maximumBytes: SkillCatalog.maximumEncodedSize))
    }

    func fetchSmallFile(_ path: String, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url(for: path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, path)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw TransportError.tooLarge(path) }
        }
        return data
    }

    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = ArtifactUpdater.chunkFetchConcurrency
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// How long the server may hold a long-poll request.
    static let longPollSeconds = 25

    public var displayName: String { baseURL.host() ?? baseURL.absoluteString }
    public var identifier: String { "http:" + baseURL.absoluteString }

    func url(for relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }

    public func fetchManifest() async throws -> Data {
        try await fetchManifest(query: nil, timeout: 30).data
    }

    func fetchManifest(query: [URLQueryItem]?, timeout: TimeInterval) async throws -> (data: Data, longPoll: Bool) {
        var components = URLComponents(url: url(for: "manifest.json"), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let manifestURL = components?.url else { throw TransportError.unavailable("bad URL") }
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, "manifest.json")
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ArtifactManifest.maximumEncodedSize { throw TransportError.tooLarge("manifest.json") }
        }
        let longPoll = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-WikiViewer-Long-Poll") == "1"
        return (data, longPoll)
    }

    /// Long poll: the server answers when a newer generation is published.
    /// A server that ignores the query (any static host) answers at once
    /// without the long-poll header; the call then waits out `interval`
    /// and fetches the manifest again, i.e. degrades to polling.
    public func waitForManifest(after generation: Int64, interval: Duration) async throws -> Data {
        let start = ContinuousClock.now
        let query = [URLQueryItem(name: "wait", value: String(generation)), URLQueryItem(name: "timeout", value: String(Self.longPollSeconds))]
        let (data, longPoll) = try await fetchManifest(query: query, timeout: TimeInterval(Self.longPollSeconds + 15))
        if longPoll || (try? ArtifactManifest.decode(data).generation).map({ $0 > generation }) == true {
            return data
        }
        let remaining = interval - (ContinuousClock.now - start)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        return try await fetchManifest()
    }

    public func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        try PublishedPath.validate(relativePath)
        var request = URLRequest(url: url(for: relativePath))
        request.timeoutInterval = 120
        try await BoundedDownload.run(request: request, session: session, destination: destination, maximumBytes: maximumBytes, name: relativePath)
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
/// Installed as the task's own delegate, so it works on a shared session.
final class BoundedDownload: NSObject, URLSessionDataDelegate, Sendable {
    struct State {
        var handle: FileHandle?
        var total: Int64 = 0
        var failure: (any Error)?
        var continuation: CheckedContinuation<Void, any Error>?
        /// Completion that arrived before the continuation was installed
        /// (a task cancelled before it was resumed can complete at once).
        var completed: Result<Void, any Error>?
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

    static func run(request: URLRequest, session: URLSession, destination: URL, maximumBytes: Int64, name: String) async throws {
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        let delegate = BoundedDownload(maximumBytes: maximumBytes, destination: destination, name: name)
        delegate.state.withLock { $0.handle = handle }
        let task = session.dataTask(with: request)
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = delegate.state.withLock { state -> Result<Void, any Error>? in
                    if let done = state.completed { return done }
                    state.continuation = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                } else {
                    task.resume()
                }
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
        let (continuation, result) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) in
            try? state.handle?.synchronize()
            try? state.handle?.close()
            state.handle = nil
            let result: Result<Void, any Error> = if let failure = state.failure ?? error { .failure(failure) } else { .success(()) }
            let c = state.continuation
            state.continuation = nil
            if c == nil { state.completed = result }
            return (c, result)
        }
        continuation?.resume(with: result)
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

    /// True once the waiting task was resumed (or a result is pending).
    var isFinished: Bool {
        state.withLock { $0.done || $0.pending != nil }
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
