//
//  StaticHTTPServer.swift
//  IndexerCore
//
//  Minimal read-only HTTP/1.1 server for a publish directory, for LAN use
//  and end-to-end tests. Serves only `manifest.json`, `generations/…`,
//  `assets/…` and `chunks/…`; rejects traversal. No authentication and no TLS: bind to
//  127.0.0.1 (default) or put it behind an HTTPS reverse proxy / VPN for
//  real use (see THREAT_MODEL.md).
//

import Foundation
import Network
import Synchronization
import WikiShared

public final class StaticHTTPServer: Sendable {
    public let root: URL
    let listener: NWListener
    let queue = DispatchQueue(label: "wikiindex.http")
    let activeConnections = ConnectionCounter()
    static let maximumConnections = 64
    /// A client must send its request headers within this time.
    static let requestDeadline: DispatchTimeInterval = .seconds(10)

    public init(root: URL, port: UInt16, bindAddress: String = "127.0.0.1") throws {
        self.root = root
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns the bound port once ready.
    public func start() async throws -> UInt16 {
        let root = root
        let queue = queue
        let active = activeConnections
        listener.newConnectionHandler = { connection in
            // Bounded resources: at most `maximumConnections` at once, and a
            // connection that has not been served within the deadline is closed.
            guard active.value.add(1, ordering: .relaxed).newValue <= Self.maximumConnections else {
                active.value.subtract(1, ordering: .relaxed)
                connection.cancel()
                return
            }
            let released = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    // .failed is followed by .cancelled; count the connection once.
                    if released.claim() { active.value.subtract(1, ordering: .relaxed) }
                    if case .failed = state { connection.cancel() }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.requestDeadline) {
                if case .ready = connection.state, !Self.isStreaming(connection) { connection.cancel() }
            }
            Self.receiveRequest(connection, root: root)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    /// Runs until cancelled.
    public func run() async throws {
        let port = try await start()
        Log.info("serving \(root.path) on port \(port)")
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
        stop()
    }

    static func receiveRequest(_ connection: NWConnection, root: URL, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                respond(connection, root: root, requestHead: head)
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                receiveRequest(connection, root: root, buffer: buffer)
            }
        }
    }

    /// Maps a request path to a file under root, or nil if not allowed.
    public static func resolve(requestPath: String, root: URL) -> URL? {
        var path = requestPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
        let relative = String(decoded.dropFirst())
        guard VaultPath.isSafeRelative(relative) else { return nil }
        let allowed = relative == "manifest.json" || relative.hasPrefix("generations/") || relative.hasPrefix("assets/") || relative.hasPrefix("chunks/")
        guard allowed, !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let url = root.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    static let streaming = StreamingSet()

    /// Connections sending a response body are exempt from the header deadline.
    static func isStreaming(_ connection: NWConnection) -> Bool {
        streaming.contains(connection)
    }

    static func respond(_ connection: NWConnection, root: URL, requestHead: String) {
        streaming.insert(connection)
        let requestLine = requestHead.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            sendStatus(connection, 405, "Method Not Allowed")
            return
        }
        guard let url = resolve(requestPath: String(parts[1]), root: root),
              let handle = try? FileHandle(forReadingFrom: url),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
            sendStatus(connection, 404, "Not Found")
            return
        }
        let contentType = url.pathExtension == "json" ? "application/json" : "application/octet-stream"
        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: \(contentType)\r\nCache-Control: \(url.lastPathComponent == "manifest.json" ? "no-cache" : "public, max-age=31536000, immutable")\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            guard error == nil, parts[0] == "GET" else {
                try? handle.close()
                streaming.remove(connection)
                connection.cancel()
                return
            }
            sendChunks(connection, handle: handle)
        })
    }

    static func sendChunks(_ connection: NWConnection, handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                streaming.remove(connection)
                connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                streaming.remove(connection)
                connection.cancel()
            } else {
                sendChunks(connection, handle: handle)
            }
        })
    }

    static func sendStatus(_ connection: NWConnection, _ code: Int, _ text: String) {
        streaming.remove(connection)
        let response = "HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class ConnectionCounter: Sendable {
    let value = Atomic<Int>(0)
}

final class StreamingSet: Sendable {
    private let ids = Mutex<Set<ObjectIdentifier>>([])
    func insert(_ c: NWConnection) { _ = ids.withLock { $0.insert(ObjectIdentifier(c)) } }
    func contains(_ c: NWConnection) -> Bool { ids.withLock { $0.contains(ObjectIdentifier(c)) } }
    func remove(_ c: NWConnection) { _ = ids.withLock { $0.remove(ObjectIdentifier(c)) } }
}

final class ResumeOnce: Sendable {
    private let done = Atomic<Bool>(false)
    func claim() -> Bool { !done.exchange(true, ordering: .relaxed) }
}
