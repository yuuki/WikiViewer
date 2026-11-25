//
//  StaticHTTPServer.swift
//  IndexerCore
//
//  Minimal HTTP/1.1 server for a publish directory, for LAN use and
//  end-to-end tests. Serves only `manifest.json`, `generations/…`,
//  `assets/…`, `chunks/…`, `packs/…` and `requests/…` (request status);
//  rejects traversal. No TLS: bind to 127.0.0.1 (default) or put it behind
//  an HTTPS reverse proxy / VPN for real use (see THREAT_MODEL.md).
//
//  Its one way in: with an inbox and a token, `POST /requests` takes a
//  HostRequest from the app (bearer token, at most 512 KiB, validated) and
//  writes it to the inbox for `wikiindex requests`. Without them every
//  POST is refused, as before.
//
//  Two things make updates fast over a high-latency link:
//   - persistent connections: a client fetching many small files reuses one
//     connection instead of a TCP (and, behind a proxy, TLS) handshake each;
//   - long polling: `GET /manifest.json?wait=N` is answered as soon as a
//     generation newer than N is published (or after `timeout` seconds, at
//     most 55), so an open app learns about a publication within a second
//     without polling. Such responses carry `X-WikiViewer-Long-Poll: 1`; a
//     plain static server ignores the query and the client falls back to
//     polling.
//

import Foundation
import Network
import Synchronization
import WikiShared

public final class StaticHTTPServer: Sendable {
    public let root: URL
    /// Where `POST /requests` puts requests; nil refuses every POST.
    let requestInbox: RequestInbox?
    let listener: NWListener
    let queue = DispatchQueue(label: "wikiindex.http")
    let activeConnections = ConnectionCounter()
    static let maximumConnections = 64
    /// A client must send its request headers within this time.
    static let requestDeadline: DispatchTimeInterval = .seconds(10)
    /// An idle persistent connection is closed after this time.
    static let keepAliveTimeout: DispatchTimeInterval = .seconds(15)
    static let longPollDefaultSeconds = 25
    static let longPollMaximumSeconds = 55
    static let longPollInterval: DispatchTimeInterval = .milliseconds(200)
    public static let longPollHeader = "X-WikiViewer-Long-Poll"

    public init(root: URL, port: UInt16, bindAddress: String = "127.0.0.1", requestInbox: RequestInbox? = nil) throws {
        self.root = root
        self.requestInbox = requestInbox
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Lets this process read files that iCloud Drive has evicted ("dataless"
    /// files, left as placeholders when the Mac runs short of space): a read
    /// then downloads the content instead of failing. A background process
    /// such as a LaunchAgent may not do so by default, and the publish
    /// directory is often an iCloud Drive folder.
    static func allowMaterializingDatalessFiles() {
        if setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON) != 0 {
            Log.warning("cannot allow reading files evicted by iCloud Drive: \(String(cString: strerror(errno)))")
        }
    }

    /// Starts listening; returns the bound port once ready.
    public func start() async throws -> UInt16 {
        Self.allowMaterializingDatalessFiles()
        let root = root
        let queue = queue
        let active = activeConnections
        let inbox = requestInbox
        listener.newConnectionHandler = { connection in
            // Bounded resources: at most `maximumConnections` at once, and a
            // connection that does not send a request in time is closed.
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
            HTTPConnection(connection: connection, root: root, queue: queue, inbox: inbox).waitForRequest(buffer: Data())
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

    /// Maps a request path to a file under root, or nil if not allowed.
    public static func resolve(requestPath: String, root: URL) -> URL? {
        var path = requestPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
        let relative = String(decoded.dropFirst())
        guard VaultPath.isSafeRelative(relative) else { return nil }
        let allowed = relative == "manifest.json" || ["generations/", "assets/", "chunks/", "packs/", "requests/"].contains { relative.hasPrefix($0) }
        guard allowed, !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let url = root.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    /// `wait` and `timeout` of a long-poll request for the manifest.
    static func longPoll(requestPath: String) -> (after: Int64, seconds: Int)? {
        guard let components = URLComponents(string: requestPath), components.path == "/manifest.json",
              let items = components.queryItems,
              let wait = items.first(where: { $0.name == "wait" })?.value.flatMap(Int64.init) else { return nil }
        let seconds = items.first(where: { $0.name == "timeout" })?.value.flatMap(Int.init) ?? longPollDefaultSeconds
        return (wait, min(max(seconds, 0), longPollMaximumSeconds))
    }

    /// Generation of the published manifest, if readable.
    static func publishedGeneration(root: URL) -> Int64? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { return nil }
        return try? ArtifactManifest.decode(data).generation
    }
}

/// One client connection: reads requests one after another (HTTP/1.1
/// persistent connections) until the client closes, asks to close, or stays
/// idle past the deadline.
final class HTTPConnection: Sendable {
    let connection: NWConnection
    let root: URL
    let queue: DispatchQueue
    let inbox: RequestInbox?
    /// Number of the request being waited for, or nil while responding (a
    /// response, including a long poll, is exempt from the idle deadline).
    private let waitingFor = Mutex<Int?>(nil)
    private let served = Atomic<Int>(0)

    init(connection: NWConnection, root: URL, queue: DispatchQueue, inbox: RequestInbox? = nil) {
        self.connection = connection
        self.root = root
        self.queue = queue
        self.inbox = inbox
    }

    func waitForRequest(buffer: Data) {
        let number = served.load(ordering: .relaxed)
        waitingFor.withLock { $0 = number }
        let deadline = number == 0 ? StaticHTTPServer.requestDeadline : StaticHTTPServer.keepAliveTimeout
        queue.asyncAfter(deadline: .now() + deadline) { [self] in
            if waitingFor.withLock({ $0 == number }) { connection.cancel() }
        }
        receive(buffer: buffer)
    }

    private func receive(buffer: Data) {
        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let rest = Data(buffer[headerEnd.upperBound...])
            waitingFor.withLock { $0 = nil }
            respond(requestHead: head, leftover: rest)
            return
        }
        guard buffer.count <= 16 * 1024 else {
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (isComplete && buffer.range(of: Data("\r\n\r\n".utf8)) == nil) {
                connection.cancel()
            } else {
                receive(buffer: buffer)
            }
        }
    }

    private func respond(requestHead: String, leftover: Data) {
        let lines = requestHead.split(separator: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let headers = lines.dropFirst().map { $0.lowercased() }
        // HTTP/1.1 is persistent unless the client says otherwise; 1.0 is not.
        let keepAlive = parts.count >= 3 && parts[2] == "HTTP/1.1" && !headers.contains { $0.hasPrefix("connection:") && $0.contains("close") }
        if parts.count >= 2, parts[0] == "POST" {
            receivePost(target: String(parts[1]), headerLines: lines.dropFirst().map(String.init), leftover: leftover, keepAlive: keepAlive)
            return
        }
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            sendStatus(405, "Method Not Allowed", keepAlive: false)
            return
        }
        let target = String(parts[1])
        let isHead = parts[0] == "HEAD"
        guard let url = StaticHTTPServer.resolve(requestPath: target, root: root) else {
            sendStatus(404, "Not Found", keepAlive: keepAlive, leftover: leftover)
            return
        }
        if let poll = StaticHTTPServer.longPoll(requestPath: target) {
            let deadline = DispatchTime.now() + .seconds(poll.seconds)
            waitForGeneration(after: poll.after, until: deadline) { [self] in
                sendFile(url, head: isHead, keepAlive: keepAlive, leftover: leftover, extraHeaders: "\(StaticHTTPServer.longPollHeader): 1\r\n")
            }
        } else {
            sendFile(url, head: isHead, keepAlive: keepAlive, leftover: leftover, extraHeaders: "")
        }
    }

    /// Calls `body` once the published generation is newer than `after`, the
    /// deadline passes, or the manifest is unreadable. Stops if the client
    /// goes away.
    private func waitForGeneration(after: Int64, until deadline: DispatchTime, _ body: @escaping @Sendable () -> Void) {
        let generation = StaticHTTPServer.publishedGeneration(root: root)
        if generation == nil || generation! > after || DispatchTime.now() >= deadline {
            body()
            return
        }
        queue.asyncAfter(deadline: .now() + StaticHTTPServer.longPollInterval) { [self] in
            switch connection.state {
            case .cancelled, .failed: return
            default: waitForGeneration(after: after, until: deadline, body)
            }
        }
    }

    private func sendFile(_ url: URL, head: Bool, keepAlive: Bool, leftover: Data, extraHeaders: String) {
        // Opened and first read off the server's queue: reading a file that
        // iCloud Drive evicted downloads it first, and that must not stall
        // every other connection.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // The size comes from the opened file, and exactly that many bytes
            // are sent: `manifest.json` may be replaced (renamed over)
            // meanwhile, and on a persistent connection a length mismatch
            // would corrupt the next response.
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else {
                sendStatus(404, "Not Found", keepAlive: keepAlive, leftover: leftover)
                return
            }
            let size = Int64(end)
            // The first block is read before the status line, so a file that
            // cannot be read (evicted and not downloadable) is answered with
            // an error instead of a connection dropped mid-body.
            var first = Data()
            if !head, size > 0 {
                guard let block = try? handle.read(upToCount: Int(min(size, Self.blockSize))), !block.isEmpty else {
                    try? handle.close()
                    Log.warning("cannot read \(url.path)")
                    sendStatus(503, "Service Unavailable", keepAlive: keepAlive, leftover: leftover)
                    return
                }
                first = block
            }
            let contentType = url.pathExtension == "json" ? "application/json" : "application/octet-stream"
            let cache = url.lastPathComponent == "manifest.json" ? "no-cache" : "public, max-age=31536000, immutable"
            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: \(contentType)\r\nCache-Control: \(cache)\r\n\(extraHeaders)Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
            connection.send(content: Data(header.utf8) + first, completion: .contentProcessed { [self] error in
                guard error == nil, !head else {
                    try? handle.close()
                    finish(error == nil && keepAlive, leftover: leftover)
                    return
                }
                sendBody(handle, remaining: size - Int64(first.count), keepAlive: keepAlive, leftover: leftover)
            })
        }
    }

    static let blockSize: Int64 = 256 * 1024

    private func sendBody(_ handle: FileHandle, remaining: Int64, keepAlive: Bool, leftover: Data) {
        guard remaining > 0 else {
            try? handle.close()
            finish(keepAlive, leftover: leftover)
            return
        }
        let chunk = (try? handle.read(upToCount: Int(min(remaining, Self.blockSize)))) ?? nil
        guard let chunk, !chunk.isEmpty else {
            // Shorter than announced (truncated underneath): the response
            // cannot be completed, so the connection must not be reused.
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil {
                try? handle.close()
                connection.cancel()
            } else {
                sendBody(handle, remaining: remaining - Int64(chunk.count), keepAlive: keepAlive, leftover: leftover)
            }
        })
    }

    // MARK: Requests

    /// Reads a POST body (Content-Length only, no chunked encoding) and
    /// hands it to the inbox. The connection is not reused after a refusal
    /// whose body was not read.
    private func receivePost(target: String, headerLines: [String], leftover: Data, keepAlive: Bool) {
        guard let inbox else {
            sendStatus(405, "Method Not Allowed", keepAlive: false)
            return
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        guard path == "/requests" else {
            sendStatus(404, "Not Found", keepAlive: false)
            return
        }
        guard inbox.authorize(HTTPConnection.header("authorization", in: headerLines)) else {
            sendStatus(401, "Unauthorized", keepAlive: false)
            return
        }
        guard let length = HTTPConnection.header("content-length", in: headerLines).flatMap({ Int($0) }), length >= 0 else {
            sendStatus(411, "Length Required", keepAlive: false)
            return
        }
        guard length <= HostRequest.maximumEncodedSize else {
            sendStatus(413, "Content Too Large", keepAlive: false)
            return
        }
        // The body, like the headers, must arrive in time.
        let finished = ResumeOnce()
        queue.asyncAfter(deadline: .now() + StaticHTTPServer.requestDeadline) { [self] in
            if finished.claim() { connection.cancel() }
        }
        readBody(length: length, buffer: leftover) { [self] body, rest in
            guard finished.claim() else { return }
            guard let body else {
                connection.cancel()
                return
            }
            switch inbox.accept(body) {
            case .accepted: sendStatus(202, "Accepted", keepAlive: keepAlive, leftover: rest)
            case .invalid: sendStatus(400, "Bad Request", keepAlive: keepAlive, leftover: rest)
            case .failed: sendStatus(500, "Internal Server Error", keepAlive: false)
            }
        }
    }

    private func readBody(length: Int, buffer: Data, _ completion: @escaping @Sendable (Data?, Data) -> Void) {
        if buffer.count >= length {
            completion(Data(buffer.prefix(length)), Data(buffer.dropFirst(length)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count >= length {
                completion(Data(buffer.prefix(length)), Data(buffer.dropFirst(length)))
            } else if error != nil || isComplete {
                completion(nil, Data())
            } else {
                readBody(length: length, buffer: buffer, completion)
            }
        }
    }

    /// The value of a header (case-insensitive name, value as sent).
    static func header(_ name: String, in lines: [String]) -> String? {
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func sendStatus(_ code: Int, _ text: String, keepAlive: Bool, leftover: Data = Data()) {
        let response = "HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] error in
            finish(error == nil && keepAlive, leftover: leftover)
        })
    }

    /// After a response: wait for the next request or close.
    private func finish(_ keepAlive: Bool, leftover: Data) {
        guard keepAlive else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                connection.cancel()
            })
            return
        }
        served.add(1, ordering: .relaxed)
        waitForRequest(buffer: leftover)
    }
}

final class ConnectionCounter: Sendable {
    let value = Atomic<Int>(0)
}

final class ResumeOnce: Sendable {
    private let done = Atomic<Bool>(false)
    func claim() -> Bool { !done.exchange(true, ordering: .relaxed) }
}
