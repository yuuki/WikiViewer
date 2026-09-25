import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

/// Regressions for defects found in review.
@Suite struct ReviewRegressionTests {
    func emptyVault() throws -> Env {
        let tmp = TempDir()
        let vault = tmp.sub("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        var env = try Env(copyFixture: false, vault: vault)
        env = Env(tmp: tmp, vault: vault, config: env.config)
        return env
    }

    @Test func caseOnlyRenameDoesNotDuplicate() async throws {
        let env = try emptyVault()
        try env.write("a/Note.md", "# Note")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        #expect(rename(env.vault.appendingPathComponent("a/Note.md").path, env.vault.appendingPathComponent("a/note.md").path) == 0)
        _ = try await indexer.reconcile()
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try String.fetchAll(db, sql: "SELECT path FROM notes") == ["a/note.md"])
            #expect(try Int.fetchOne(db, sql: "SELECT note_count FROM folders WHERE path = 'a'") == 1)
        }
    }

    @Test func crlfFrontmatterIsParsed() async throws {
        let env = try emptyVault()
        try env.write("c.md", "---\r\ntags: [crlf]\r\ntitle: CRLF Title\r\n---\r\n# Body\r\n[[c]]\r\n")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "SELECT title FROM notes") == "CRLF Title")
            #expect(try String.fetchAll(db, sql: "SELECT name FROM tags") == ["crlf"])
            #expect(try String.fetchOne(db, sql: "SELECT body FROM notes")?.hasPrefix("# Body") == true)
        }
    }

    @Test func yamlAliasBombIsNotExpanded() async throws {
        let env = try emptyVault()
        var yaml = "a0: &a0 [\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\",\"xxxxxxxxxx\"]\n"
        for i in 1...8 {
            yaml += "a\(i): &a\(i) [" + Array(repeating: "*a\(i - 1)", count: 10).joined(separator: ",") + "]\n"
        }
        try env.write("bomb.md", "---\n\(yaml)tags: [ok]\n---\nbody")
        let indexer = try Indexer(configuration: env.config)
        let start = ContinuousClock.now
        _ = try await indexer.reconcile()
        #expect(ContinuousClock.now - start < .seconds(10))
        try await indexer.query { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "SELECT frontmatter FROM notes") == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") == 1)
        }
        let result = try #require(try await indexer.publish())
        #expect(result.manifest.database.byteSize < 2 * 1024 * 1024)
    }

    @Test func symlinkedDirectoryComponentIsNotFollowed() async throws {
        let env = try emptyVault()
        try env.write("a/x.md", "# inside")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        let outside = env.tmp.sub("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# SECRET-OUTSIDE".utf8).write(to: outside.appendingPathComponent("x.md"))
        try FileManager.default.removeItem(at: env.vault.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(at: env.vault.appendingPathComponent("a"), withDestinationURL: outside)
        _ = try await indexer.process(paths: ["a", "a/x.md"])
        try await indexer.query { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE body LIKE '%SECRET-OUTSIDE%'") == 0)
        }
    }

    @Test func removedTextDoesNotLingerInPublishedDatabase() async throws {
        let env = try emptyVault()
        try env.write("n.md", "password: hunter2-SECRET-TOKEN and more text " + String(repeating: "filler ", count: 200))
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try env.write("n.md", "redacted")
        _ = try await indexer.process(paths: ["n.md"])
        let result = try #require(try await indexer.publish())
        let bytes = try Data(contentsOf: result.databaseURL)
        #expect(bytes.range(of: Data("hunter2-SECRET-TOKEN".utf8)) == nil, "secure_delete zeroes removed content")
    }

    @Test func secondIndexerOnSameStateIsRefused() throws {
        let env = try emptyVault()
        let first = try Indexer(configuration: env.config)
        #expect(throws: IndexerError.self) { _ = try Indexer(configuration: env.config) }
        _ = first
    }

    @Test func interruptedResolutionIsRedoneAtStartup() async throws {
        let env = try emptyVault()
        try env.write("A.md", "[[B]]")
        try env.write("B.md", "# B")
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            // Simulate a crash after batches committed but before resolution.
            try await indexer.builder.writer.write { db in
                try db.execute(sql: "UPDATE links SET target_note_id = NULL")
                try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES ('resolution_pending', '1')")
            }
        }
        let restarted = try Indexer(configuration: env.config)
        #expect(await restarted.hasUnpublishedChanges)
        #expect(try await restarted.query { db in try linkTarget(db, from: "A.md", raw: "B") } == "B.md")
    }

    @Test func fileBecomingDirectoryAndBack() async throws {
        let env = try emptyVault()
        try env.write("x.md", "# file")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try env.remove("x.md")
        try env.write("x.md/y.md", "# nested")
        _ = try await indexer.process(paths: ["x.md"])
        #expect(try await indexer.query { db in try String.fetchAll(db, sql: "SELECT path FROM notes") } == ["x.md/y.md"])
        try env.remove("x.md")
        try env.write("x.md", "# file again")
        _ = try await indexer.process(paths: ["x.md"])
        #expect(try await indexer.query { db in try String.fetchAll(db, sql: "SELECT path FROM notes") } == ["x.md"])
    }

    @Test func unpublishedGenerationFilesAreRemoved() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try env.write("New.md", "# new")
        _ = try await indexer.process(paths: ["New.md"])
        await #expect(throws: PublisherError.self) { try await indexer.publish(failpoint: .beforeManifestRename) }
        let r = try #require(try await indexer.publish())
        #expect(r.manifest.generation == 3)
        let gens = try FileManager.default.contentsOfDirectory(atPath: env.config.publishDirectory.appendingPathComponent("generations").path)
        #expect(!gens.contains { $0.hasPrefix("viewer-000002") }, "orphans of the failed publication removed")
    }

    @Test func tagsAreUnicodeCaseInsensitive() async throws {
        let env = try emptyVault()
        try env.write("a.md", "#Über")
        try env.write("b.md", "#über")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM tags") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT note_count FROM tags") == 2)
        }
    }
}

@Suite struct SchemaDriftTests {
    @Test func staleBuilderSchemaIsRebuilt() async throws {
        let env = try Env(copyFixture: true)
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
        }
        // Same user_version, different SQL (e.g. an older FTS definition).
        let queue = try DatabaseQueue(path: env.config.builderDatabaseURL.path)
        try await queue.write { db in try db.execute(sql: "CREATE INDEX extra_idx ON notes(size)") }
        try queue.close()
        let indexer = try Indexer(configuration: env.config)
        let stats = try await indexer.reconcile()
        #expect(stats.index.notesWritten == 11, "rebuilt from the vault")
        _ = try #require(try await indexer.publish())
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }
}
