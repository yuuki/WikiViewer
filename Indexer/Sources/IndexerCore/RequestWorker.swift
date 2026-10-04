//
//  RequestWorker.swift
//  IndexerCore
//
//  `wikiindex requests`: takes requests from the inbox one at a time and
//  reports each one's progress as `<publish>/requests/<id>.json`, which the
//  app reads back through the same transport as the snapshots.
//
//  The worker itself never writes to the vault and never talks to Claude.
//  It runs a runner (scripts/claude-request.py by default) with the request
//  file; the runner starts Claude Code in the vault with tools confined to
//  wiki/ and prints one JSON line with the result. The answer note then
//  reaches the app with the next snapshot, like any other note.
//

import Foundation
import WikiShared

public struct RequestWorkerConfiguration: Sendable {
    /// Where requests arrive (`<publish>/inbox` by default).
    public var inbox: URL
    /// The publish directory; status files go to `<publish>/requests/`.
    public var publishDirectory: URL
    /// The vault, for checking the answer paths a runner reports.
    public var vault: URL
    /// Executable run once per request, with the request file as its only
    /// argument and the vault as its working directory. Nil fails every
    /// request that needs Claude.
    public var runner: URL?
    /// A runner taking longer than this is stopped and the request fails.
    public var runnerTimeout: Duration = .seconds(30 * 60)
    /// Vault folders an answer may be in.
    public var answerFolders = ["wiki/"]
    /// Status files are deleted this long after they were last updated.
    public var statusRetention: TimeInterval = 30 * 24 * 3600
    /// Requests handled are appended here (JSON lines), if set.
    public var log: URL?
    /// Reading signals (#42) are stored here; nil refuses them.
    public var signals: SignalStore?

    public init(inbox: URL, publishDirectory: URL, vault: URL) {
        self.inbox = inbox
        self.publishDirectory = publishDirectory
        self.vault = vault
    }

    public var statusDirectory: URL { publishDirectory.appendingPathComponent("requests", isDirectory: true) }

    /// Refuses configurations that would put the queue or the status files
    /// in the vault.
    public func validate() throws {
        for (name, dir) in [("inbox", inbox), ("publish", publishDirectory)] + (signals.map { [("signals", $0.directory)] } ?? [])
        where dir.isInside(vault) || dir == vault {
            throw IndexerError.unsafeLocation("\(name) directory \(dir.path) is inside the vault")
        }
    }
}

/// What a runner prints as its last line of output.
public struct RunnerResult: Codable, Sendable, Equatable {
    public var answerPath: String?
    public var message: String?
    public var findings: [HostRequestStatus.Finding]?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case answerPath = "answer_path", message, findings, error
    }

    /// The last line of `output` that decodes as a result.
    public static func parse(_ output: String) -> RunnerResult? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let result = try? JSONDecoder().decode(RunnerResult.self, from: data) else { continue }
            return result
        }
        return nil
    }
}

public final class RequestWorker: Sendable {
    public let configuration: RequestWorkerConfiguration

    public init(configuration: RequestWorkerConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: configuration.inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.statusDirectory, withIntermediateDirectories: true)
        self.configuration = configuration
    }

    /// Runs until cancelled, checking the inbox every `interval` (iCloud
    /// Drive delivers files without reliable events, so this polls).
    public func run(interval: Duration = .seconds(5)) async throws {
        Log.info("requests: watching \(configuration.inbox.path)")
        while !Task.isCancelled {
            _ = await processPending()
            removeExpiredStatuses()
            try await Task.sleep(for: interval)
        }
    }

    /// Handles every request in the inbox, oldest first. Returns how many
    /// were handled.
    @discardableResult
    public func processPending() async -> Int {
        let files = pendingFiles()
        guard !files.isEmpty else { return 0 }
        // Announce everything waiting first, so the app shows "queued"
        // rather than nothing while an earlier request takes minutes.
        var requests: [(URL, HostRequest)] = []
        for file in files {
            guard let id = HostRequest.id(fromFileName: file.lastPathComponent) else { continue }
            do {
                let request = try HostRequest.decode(try readBounded(file))
                guard request.id == id else { throw HostRequest.ValidationError.missing("matching id") }
                if let status = readStatus(id), status.state.isFinal {
                    // Handled before (e.g. sent twice); nothing to do.
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                writeStatus(HostRequestStatus(id: id, kind: request.kind, state: .queued))
                requests.append((file, request))
            } catch {
                Log.warning("requests: rejecting \(file.lastPathComponent): \(error)")
                writeStatus(HostRequestStatus(id: id, kind: .ask, state: .failed, message: "The request was not valid: \(error)"))
                try? FileManager.default.removeItem(at: file)
            }
        }
        var handled = 0
        for (file, request) in requests {
            if Task.isCancelled { break }
            let status = await handle(request)
            writeStatus(status)
            appendLog(request, status)
            try? FileManager.default.removeItem(at: file)
            handled += 1
        }
        return handled
    }

    /// `<uuid>.json` files in the inbox, oldest first.
    func pendingFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: configuration.inbox, includingPropertiesForKeys: keys)) ?? []
        var dated: [(url: URL, date: Date)] = []
        for url in urls where HostRequest.id(fromFileName: url.lastPathComponent) != nil {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            dated.append((url, values.contentModificationDate ?? .distantPast))
        }
        dated.sort { a, b in
            a.date != b.date ? a.date < b.date : a.url.lastPathComponent < b.url.lastPathComponent
        }
        return dated.map(\.url)
    }

    func handle(_ request: HostRequest) async -> HostRequestStatus {
        let id = request.id
        if request.kind == .signals {
            guard let signals = configuration.signals else {
                return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: "This Mac does not store reading history (wikiindex requests --signals).")
            }
            do {
                let count = try signals.append(request)
                return HostRequestStatus(id: id, kind: request.kind, state: .done, message: "Stored \(count) reading events.")
            } catch {
                return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: "Could not store reading history: \(error)")
            }
        }
        guard let runner = configuration.runner else {
            return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: "No runner is configured on the Mac (wikiindex requests --runner).")
        }
        writeStatus(HostRequestStatus(id: id, kind: request.kind, state: .processing))
        Log.info("requests: running \(request.kind.rawValue) \(id.uuidString.lowercased())")
        // The runner reads the request from a private copy, not the inbox
        // (which the app's transport may rewrite meanwhile).
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("wikiviewer-request-\(id.uuidString.lowercased()).json")
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            try RequestInbox.writeAtomically(try request.encoded(), to: copy)
            let output = try await ProcessRunner.run(runner, arguments: [copy.path], directory: configuration.vault,
                                                     environment: ["WIKIVIEWER_VAULT": configuration.vault.path],
                                                     timeout: configuration.runnerTimeout)
            guard output.status == 0, let result = RunnerResult.parse(output.stdout), result.error == nil else {
                let reason = RunnerResult.parse(output.stdout)?.error ?? output.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit status \(output.status)"
                return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: String(reason.prefix(500)))
            }
            var answer: String?
            if let path = result.answerPath {
                guard let checked = checkedAnswerPath(path) else {
                    return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: "The runner reported an answer outside \(configuration.answerFolders.joined(separator: ", ")): \(path)")
                }
                answer = checked
            }
            return HostRequestStatus(id: id, kind: request.kind, state: .done, message: result.message.map { String($0.prefix(2000)) },
                                     answerPath: answer, findings: result.findings.map { Array($0.prefix(50)) })
        } catch {
            return HostRequestStatus(id: id, kind: request.kind, state: .failed, message: "\(error)")
        }
    }

    /// The vault-relative answer path if it names an existing note inside
    /// one of `answerFolders`, never through a symbolic link.
    func checkedAnswerPath(_ raw: String) -> String? {
        guard let path = VaultPath.normalizeRelative(raw), VaultPath.isSafeRelative(path), path.hasSuffix(".md"),
              configuration.answerFolders.contains(where: { path.hasPrefix($0) }),
              !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        guard let meta = VaultWalker.meta(vault: configuration.vault, relativePath: path), !meta.isDirectory else { return nil }
        return path
    }

    // MARK: Status files

    func statusURL(_ id: UUID) -> URL {
        configuration.statusDirectory.appendingPathComponent(HostRequest.fileName(for: id))
    }

    func readStatus(_ id: UUID) -> HostRequestStatus? {
        guard let data = try? Data(contentsOf: statusURL(id)) else { return nil }
        return try? HostRequestStatus.decode(data)
    }

    func writeStatus(_ status: HostRequestStatus) {
        do {
            try RequestInbox.writeAtomically(try HostRequest.encoder.encode(status), to: statusURL(status.id))
        } catch {
            Log.warning("requests: cannot write status of \(status.id): \(error)")
        }
    }

    /// Deletes status files older than the retention period.
    func removeExpiredStatuses(now: Date = Date()) {
        let dir = configuration.statusDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard HostRequest.id(fromFileName: url.lastPathComponent) != nil,
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > configuration.statusRetention else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func appendLog(_ request: HostRequest, _ status: HostRequestStatus) {
        guard let log = configuration.log, request.kind != .signals else { return }
        struct Line: Encodable {
            var request: HostRequest
            var status: HostRequestStatus
        }
        guard var data = try? HostRequest.encoder.encode(Line(request: request, status: status)) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: HostRequest.maximumEncodedSize + 1) ?? Data()
        guard data.count <= HostRequest.maximumEncodedSize else { throw HostRequest.ValidationError.tooLarge("request") }
        return data
    }
}

/// Runs a process with a timeout, collecting its output (bounded).
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static let maximumOutput = 1 << 20

    static func run(_ executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: Duration) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        let exit = ExitGate()
        process.terminationHandler = { _ in exit.signal() }
        try process.run()
        let timer = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning {
                Log.warning("runner timed out; stopping it")
                process.terminate()
            }
        }
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            process.terminate()
        }
        timer.cancel()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
        return Output(status: process.terminationStatus, stdout: stdout.text, stderr: stderr.text)
    }
}

/// Resumes one waiter once the process has exited, whichever comes first.
final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        exited = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.count < ProcessRunner.maximumOutput {
            data.append(chunk.prefix(ProcessRunner.maximumOutput - data.count))
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
