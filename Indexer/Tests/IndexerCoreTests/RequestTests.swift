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

    // MARK: Skills

    func writeSkill(_ env: Env, _ folder: String, _ frontmatter: String) throws {
        try env.write(".claude/skills/\(folder)/SKILL.md", "---\n\(frontmatter)\n---\n\n# Body\n")
    }

    @Test func scannerReadsTheVaultsSkills() throws {
        let env = try Env(copyFixture: true)
        try writeSkill(env, "wiki-gap", "name: wiki-gap\ndescription: >\n  Finds gaps\n  between clusters.\nargument-hint: \"[topic]\"")
        try writeSkill(env, "hidden", "name: hidden\ndescription: x\ndisable-model-invocation: true")
        try writeSkill(env, "internal", "name: internal\ndescription: x\nuser-invocable: false")
        try writeSkill(env, "Bad Name", "name: bad\ndescription: x")
        try writeSkill(env, "no-frontmatter", "")
        try env.write(".claude/skills/stray.md", "---\nname: stray\ndescription: x\n---\n")
        let catalog = SkillScanner(vault: env.vault).scan()
        #expect(catalog.skills == [SkillCatalog.Skill(name: "wiki-gap", description: "Finds gaps between clusters.", argumentHint: "[topic]")])
        try writeSkill(env, "wiki-query", "name: wiki-query\ndescription: Answers questions.")
        #expect(SkillScanner(vault: env.vault).scan().skills.map(\.name) == ["wiki-gap", "wiki-query"])
        #expect(SkillScanner(vault: env.vault, allowed: ["wiki-query"]).scan().skills.map(\.name) == ["wiki-query"])
        #expect(SkillScanner(vault: env.vault, denied: ["wiki-query"]).scan().skills.map(\.name) == ["wiki-gap"])
    }

    @Test func scannerReadsAgentsSkillsAndResolvesLinksOnce() throws {
        let env = try Env(copyFixture: true)
        let fm = FileManager.default
        func link(_ path: String, to target: String) throws {
            let url = env.vault.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
        // In .claude, linked from .agents.
        try writeSkill(env, "wiki-gap", "name: wiki-gap\ndescription: Claude's.")
        try link(".agents/skills/wiki-gap", to: "../../.claude/skills/wiki-gap")
        // In .agents, linked from .claude.
        try env.write(".agents/skills/defuddle/SKILL.md", "---\nname: defuddle\ndescription: Shared.\n---\n")
        try link(".claude/skills/defuddle", to: "../../.agents/skills/defuddle")
        // Only in .agents.
        try env.write(".agents/skills/reading-inbox/SKILL.md", "---\nname: reading-inbox\ndescription: Agents only.\n---\n")
        // Different copies under one name: .claude wins.
        try writeSkill(env, "wiki-ingest", "name: wiki-ingest\ndescription: Claude copy.")
        try env.write(".agents/skills/wiki-ingest/SKILL.md", "---\nname: wiki-ingest\ndescription: Agents copy.\n---\n")
        // Elsewhere in the vault through a link, and the same file under a second name.
        try env.write(".gemini/skills/create-tech-note/SKILL.md", "---\nname: create-tech-note\ndescription: Gemini's.\n---\n")
        try link(".agents/skills/create-tech-note", to: "../../.gemini/skills/create-tech-note")
        try link(".agents/skills/tech-note-alias", to: "../../.gemini/skills/create-tech-note")
        // A broken link.
        try link(".claude/skills/gone", to: "../../.agents/skills/missing")

        let entries = SkillScanner(vault: env.vault).entries()
        #expect(entries.map(\.skill.name) == ["create-tech-note", "defuddle", "reading-inbox", "wiki-gap", "wiki-ingest"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.skill.name, $0) })
        #expect(byName["wiki-gap"]?.isClaudeSkill == true)
        #expect(byName["defuddle"]?.isClaudeSkill == true)
        #expect(byName["defuddle"]?.file.path.hasSuffix(".agents/skills/defuddle/SKILL.md") == true)
        #expect(byName["reading-inbox"]?.isClaudeSkill == false)
        #expect(byName["wiki-ingest"]?.skill.description == "Claude copy.")
        #expect(byName["create-tech-note"]?.file.path.hasSuffix(".gemini/skills/create-tech-note/SKILL.md") == true)
    }

    @Test func onlyDeclaredOrListedSkillsUseTheWeb() throws {
        let env = try Env(copyFixture: true)
        try writeSkill(env, "wiki-ingest-paper", "name: wiki-ingest-paper\ndescription: Ingests.")
        try writeSkill(env, "autoresearch", "name: autoresearch\ndescription: x\nallowed-tools: Read Write WebFetch WebSearch")
        try writeSkill(env, "listed-tools", "name: listed-tools\ndescription: x\nallowed-tools:\n  - Read\n  - WebSearch")
        try writeSkill(env, "comma-tools", "name: comma-tools\ndescription: x\nallowed-tools: Read, Grep, Glob")
        try writeSkill(env, "wiki-query", "name: wiki-query\ndescription: x")
        func web(_ scanner: SkillScanner) -> [String] { scanner.scan().skills.filter { $0.usesWeb == true }.map(\.name) }
        #expect(web(SkillScanner(vault: env.vault)) == ["autoresearch", "listed-tools", "wiki-ingest-paper"])
        #expect(web(SkillScanner(vault: env.vault, webPatterns: ["wiki-q*"])) == ["autoresearch", "listed-tools", "wiki-query"])
        var none = SkillScanner(vault: env.vault)
        none.allowsWeb = false
        #expect(web(none).isEmpty)
    }

    @Test func skillNamesAreChecked() throws {
        #expect(SkillCatalog.isValidName("wiki-ingest-paper"))
        #expect(SkillCatalog.isValidName("v2.tool_x"))
        for bad in ["", "-x", ".x", "../x", "A", "x y", "x/y", "x;rm", String(repeating: "a", count: 65)] {
            #expect(!SkillCatalog.isValidName(bad), "\(bad)")
        }
        #expect(throws: HostRequest.ValidationError.missing("skill")) { try HostRequest(kind: .skill).validate() }
        #expect(throws: HostRequest.ValidationError.unsafeSkill("../x")) { try HostRequest(kind: .skill, skill: "../x").validate() }
        try HostRequest(kind: .skill, skill: "wiki-gap").validate()
    }

    @Test func workerPublishesTheCatalogAndRunsOnlyListedSkills() async throws {
        let env = try Env(copyFixture: true)
        try writeSkill(env, "wiki-gap", "name: wiki-gap\ndescription: Finds gaps.")
        var config = RequestWorkerConfiguration(inbox: env.tmp.sub("publish/inbox"), publishDirectory: env.tmp.sub("publish"), vault: env.vault)
        config.runner = try runner(in: env.tmp.url, printing: #"{"answer_path": null, "message": "ran"}"#)
        config.skills = SkillScanner(vault: env.vault)
        let worker = try RequestWorker(configuration: config)
        worker.publishSkills()
        let source = LocalFolderArtifactSource(root: env.tmp.sub("publish"))
        #expect(try await source.fetchSkillCatalog().skills.map(\.name) == ["wiki-gap"])

        let listed = HostRequest(kind: .skill, notePath: "Home.md", text: "focus", skill: "wiki-gap")
        let unlisted = HostRequest(kind: .skill, skill: "wiki-ingest")
        try await source.submitRequest(try listed.encoded(), id: listed.id)
        try await source.submitRequest(try unlisted.encoded(), id: unlisted.id)
        #expect(await worker.processPending() == 2)
        #expect(try await source.fetchRequestStatus(id: listed.id).state == .done)
        #expect(try await source.fetchRequestStatus(id: listed.id).message == "ran")

        // The runner is told where the skill is and whether Claude Code knows it.
        try env.write(".agents/skills/reading-inbox/SKILL.md", "---\nname: reading-inbox\ndescription: Agents only.\n---\n")
        let echo = env.tmp.sub("echo-runner.sh")
        try Data(#"""
            #!/bin/sh
            echo "{\"answer_path\": null, \"message\": \"$WIKIVIEWER_SKILL_INVOCABLE $WIKIVIEWER_SKILL_WEB $WIKIVIEWER_SKILL_FILE\"}"
            """#.utf8).write(to: echo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: echo.path)
        var located = config
        located.runner = echo
        let locating = try RequestWorker(configuration: located)
        let agentsOnly = HostRequest(kind: .skill, skill: "reading-inbox")
        try await source.submitRequest(try agentsOnly.encoded(), id: agentsOnly.id)
        #expect(await locating.processPending() == 1)
        let message = try #require(try await source.fetchRequestStatus(id: agentsOnly.id).message)
        #expect(message.hasPrefix("0 0 /"))
        #expect(message.hasSuffix(".agents/skills/reading-inbox/SKILL.md"))

        // An ingest skill, which needs the web, is told it may use it.
        try writeSkill(env, "wiki-ingest", "name: wiki-ingest\ndescription: Ingests a source.")
        let ingest = HostRequest(kind: .skill, text: "https://example.org/paper", skill: "wiki-ingest")
        try await source.submitRequest(try ingest.encoded(), id: ingest.id)
        #expect(await locating.processPending() == 1)
        #expect(try await source.fetchRequestStatus(id: ingest.id).message?.hasPrefix("1 1 /") == true)
        let refused = try await source.fetchRequestStatus(id: unlisted.id)
        #expect(refused.state == .failed)
        #expect(refused.message?.contains("wiki-ingest") == true)

        // Without skills, the catalog goes away and every skill is refused.
        var none = config
        none.skills = nil
        let plain = try RequestWorker(configuration: none)
        plain.publishSkills()
        await #expect(throws: TransportError.self) { try await source.fetchSkillCatalog() }
        let again = HostRequest(kind: .skill, skill: "wiki-gap")
        try await source.submitRequest(try again.encoded(), id: again.id)
        #expect(await plain.processPending() == 1)
        #expect(try await source.fetchRequestStatus(id: again.id).state == .failed)
    }
}
