import Foundation
import Testing
@testable import IndexerCore
import WikiShared
import WikiViewerKit

/// Requests from the app: the HTTP inbox, the folder inbox, the worker and
/// the runner protocol.
@Suite(.serialized) struct RequestTests {
    static let token = "0123456789abcdef-test-token"

    func ask(_ id: UUID = UUID()) -> HostRequest {
        HostRequest(id: id, kind: .ask, device: "test", notePath: "Home.md", noteTitle: "Home",
                    excerpt: "A paragraph.", question: .verify)
    }

    /// A runner that prints `output` as its last line.
    func runner(in dir: URL, printing output: String, exit status: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent("runner-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\necho 'working' >&2\ncat <<'EOF'\n\(output)\nEOF\nexit \(status)\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func inboxChecksTheTokenInConstantTime() throws {
        let tmp = TempDir()
        let inbox = try RequestInbox(directory: tmp.sub("inbox"), token: Self.token)
        #expect(inbox.authorize("Bearer \(Self.token)"))
        #expect(!inbox.authorize("Bearer \(Self.token)x"))
        #expect(!inbox.authorize("Bearer short"))
        #expect(!inbox.authorize(Self.token))
        #expect(!inbox.authorize(nil))
        #expect(throws: IndexerError.self) { try RequestInbox(directory: tmp.sub("inbox"), token: "short") }
    }

    @Test func inboxAcceptsOnlyValidRequestsAndIsIdempotent() throws {
        let tmp = TempDir()
        let inbox = try RequestInbox(directory: tmp.sub("inbox"), token: Self.token)
        let request = ask()
        #expect(inbox.accept(try request.encoded()) == .accepted)
        #expect(inbox.accept(try request.encoded()) == .accepted)
        #expect(FileManager.default.fileExists(atPath: tmp.sub("inbox/\(request.fileName)").path))
        #expect(inbox.accept(Data("{}".utf8)) == .invalid)
        var unsafe = ask()
        unsafe.notePath = "../outside.md"
        #expect(inbox.accept(try HostRequest.encoder.encode(unsafe)) == .invalid)
        var hidden = ask()
        hidden.notePath = ".obsidian/workspace.md"
        #expect(inbox.accept(try HostRequest.encoder.encode(hidden)) == .invalid)
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.sub("inbox").path)
        #expect(files == [request.fileName])
    }

    @Test func tokenFileMustBePrivate() throws {
        let tmp = TempDir()
        let file = tmp.sub("token")
        try Data(Self.token.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: IndexerError.self) { try RequestInbox.token(fromFile: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try RequestInbox.token(fromFile: file) == Self.token)
    }

    @Test func runnerResultIsTheLastJSONLine() {
        let output = "noise\n{\"answer_path\": \"wiki/a.md\", \"message\": \"ok\"}\n"
        #expect(RunnerResult.parse(output) == RunnerResult(answerPath: "wiki/a.md", message: "ok"))
        #expect(RunnerResult.parse("{\"error\": \"no\"}")?.error == "no")
        #expect(RunnerResult.parse("nothing") == nil)
    }

    func worker(_ env: Env, runner: URL?) throws -> RequestWorker {
        var config = RequestWorkerConfiguration(inbox: env.tmp.sub("publish/inbox"), publishDirectory: env.tmp.sub("publish"), vault: env.vault)
        config.runner = runner
        config.runnerTimeout = .seconds(20)
        return try RequestWorker(configuration: config)
    }

    @Test func workerRunsTheRunnerAndReportsTheAnswer() async throws {
        let env = try Env(copyFixture: true)
        try env.write("wiki/asks/Home.md", "# Answer\n")
        let worker = try worker(env, runner: try runner(in: env.tmp.url, printing: #"{"answer_path": "wiki/asks/Home.md", "message": "答えた"}"#))
        let request = ask()
        try request.encoded().write(to: env.tmp.sub("publish/inbox/\(request.fileName)"))
        #expect(await worker.processPending() == 1)
        let status = try #require(worker.readStatus(request.id))
        #expect(status.state == .done)
        #expect(status.answerPath == "wiki/asks/Home.md")
        #expect(status.message == "答えた")
        // Handled requests leave the inbox; a second pass does nothing.
        #expect(worker.pendingFiles().isEmpty)
        #expect(await worker.processPending() == 0)
    }

    @Test func workerRefusesAnswersOutsideWikiOrMissing() async throws {
        let env = try Env(copyFixture: true)
        for (answer, expected) in [("Home.md", HostRequestStatus.State.failed), ("wiki/none.md", .failed), ("wiki/../Home.md", .failed)] {
            let worker = try worker(env, runner: try runner(in: env.tmp.url, printing: #"{"answer_path": "\#(answer)"}"#))
            let request = ask()
            try request.encoded().write(to: env.tmp.sub("publish/inbox/\(request.fileName)"))
            await worker.processPending()
            #expect(worker.readStatus(request.id)?.state == expected, "\(answer)")
        }
    }

    @Test func workerReportsRunnerFailures() async throws {
        let env = try Env(copyFixture: true)
        let failing = try worker(env, runner: try runner(in: env.tmp.url, printing: #"{"error": "claude is not installed"}"#))
        let first = ask()
        try first.encoded().write(to: env.tmp.sub("publish/inbox/\(first.fileName)"))
        await failing.processPending()
        #expect(failing.readStatus(first.id)?.state == .failed)
        #expect(failing.readStatus(first.id)?.message == "claude is not installed")

        let crashing = try worker(env, runner: try runner(in: env.tmp.url, printing: "", exit: 3))
        let second = ask()
        try second.encoded().write(to: env.tmp.sub("publish/inbox/\(second.fileName)"))
        await crashing.processPending()
        #expect(crashing.readStatus(second.id)?.state == .failed)

        let none = try worker(env, runner: nil)
        let third = ask()
        try third.encoded().write(to: env.tmp.sub("publish/inbox/\(third.fileName)"))
        await none.processPending()
        #expect(none.readStatus(third.id)?.state == .failed)
    }

    @Test func workerRejectsMalformedRequestsWithAStatus() async throws {
        let env = try Env(copyFixture: true)
        let worker = try worker(env, runner: nil)
        let id = UUID()
        try Data("not json".utf8).write(to: env.tmp.sub("publish/inbox/\(HostRequest.fileName(for: id))"))
        try Data("ignored".utf8).write(to: env.tmp.sub("publish/inbox/notes.txt"))
        await worker.processPending()
        #expect(worker.readStatus(id)?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: env.tmp.sub("publish/inbox/notes.txt").path))
    }

    @Test func workerRefusesAnInboxInsideTheVault() throws {
        let env = try Env(copyFixture: true)
        let config = RequestWorkerConfiguration(inbox: env.vault.appendingPathComponent("inbox"), publishDirectory: env.tmp.sub("publish"), vault: env.vault)
        #expect(throws: IndexerError.self) { try RequestWorker(configuration: config) }
    }

    @Test func runnerTimeoutStopsIt() async throws {
        let tmp = TempDir()
        let script = tmp.sub("slow.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = ContinuousClock.now
        let output = try await ProcessRunner.run(script, arguments: [], directory: tmp.url, environment: [:], timeout: .milliseconds(300))
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(output.status != 0)
    }

    // MARK: Over HTTP

    @Test(.timeLimit(.minutes(1))) func requestTravelsOverHTTPAndItsStatusComesBack() async throws {
        let env = try Env(copyFixture: true)
        try env.write("wiki/questions/Home.md", "# Verdict\n")
        let publish = env.tmp.sub("publish")
        try FileManager.default.createDirectory(at: publish, withIntermediateDirectories: true)
        let inbox = try RequestInbox(directory: publish.appendingPathComponent("inbox"), token: Self.token)
        let server = try StaticHTTPServer(root: publish, port: 0, requestInbox: inbox)
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let request = ask()
        let wrong = HTTPArtifactSource(baseURL: url, requestToken: "wrong-token-wrong-token", session: session)
        await #expect(throws: TransportError.self) { try await wrong.submitRequest(try request.encoded(), id: request.id) }
        let anonymous = HTTPArtifactSource(baseURL: url, session: session)
        await #expect(throws: TransportError.self) { try await anonymous.submitRequest(try request.encoded(), id: request.id) }

        let source = HTTPArtifactSource(baseURL: url, requestToken: Self.token, session: session)
        try await source.submitRequest(try request.encoded(), id: request.id)
        // Sent again (the app never saw the answer): still accepted.
        try await source.submitRequest(try request.encoded(), id: request.id)
        await #expect(throws: TransportError.notFound(HostRequestStatus.publishedPath(for: request.id))) {
            try await source.fetchRequestStatus(id: request.id)
        }

        let worker = try worker(env, runner: try runner(in: env.tmp.url, printing: #"{"answer_path": "wiki/questions/Home.md", "message": "supported"}"#))
        #expect(await worker.processPending() == 1)
        let status = try await source.fetchRequestStatus(id: request.id)
        #expect(status.state == .done)
        #expect(status.answerPath == "wiki/questions/Home.md")
    }

    @Test(.timeLimit(.minutes(1))) func serverWithoutAnInboxRefusesPosts() async throws {
        let tmp = TempDir()
        let server = try StaticHTTPServer(root: tmp.url, port: 0)
        let port = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = HTTPArtifactSource(baseURL: URL(string: "http://127.0.0.1:\(port)/")!, requestToken: Self.token, session: session)
        let request = ask()
        await #expect(throws: TransportError.self) { try await source.submitRequest(try request.encoded(), id: request.id) }
        #expect(!FileManager.default.fileExists(atPath: tmp.sub("inbox").path))
    }

    @Test(.timeLimit(.minutes(1))) func oversizedPostIsRefused() async throws {
        let tmp = TempDir()
        let inbox = try RequestInbox(directory: tmp.sub("inbox"), token: Self.token)
        let server = try StaticHTTPServer(root: tmp.url, port: 0, requestInbox: inbox)
        let port = try await server.start()
        defer { server.stop() }
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/requests")!)
        post.httpMethod = "POST"
        post.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: post, from: Data(count: HostRequest.maximumEncodedSize + 1))
        #expect((response as? HTTPURLResponse)?.statusCode == 413)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.sub("inbox").path).isEmpty)
    }

    // MARK: Over a folder

    @Test func requestTravelsThroughAFolder() async throws {
        let env = try Env(copyFixture: true)
        try env.write("wiki/asks/Home.md", "# Answer\n")
        let publish = env.tmp.sub("publish")
        try FileManager.default.createDirectory(at: publish, withIntermediateDirectories: true)
        let source = LocalFolderArtifactSource(root: publish)
        let request = ask()
        try await source.submitRequest(try request.encoded(), id: request.id)
        let worker = try worker(env, runner: try runner(in: env.tmp.url, printing: #"{"answer_path": "wiki/asks/Home.md"}"#))
        #expect(await worker.processPending() == 1)
        #expect(try await source.fetchRequestStatus(id: request.id).state == .done)

        let demo = LocalFolderArtifactSource(root: publish, acceptsRequests: false)
        await #expect(throws: TransportError.self) { try await demo.submitRequest(try request.encoded(), id: request.id) }
    }
}
