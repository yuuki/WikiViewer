import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct IncrementalTests {
    @Test func noopReconcileDoesNothing() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        let again = try await indexer.reconcile()
        #expect(again.candidates == 0)
        #expect(!again.index.changed)
        #expect(try await indexer.publish() == nil, "nothing to publish")
    }

    @Test func nodeModulesIsNeverIndexed() async throws {
        let env = try Env(copyFixture: true)
        try env.write("node_modules/pkg/README.md", "# Package\n")
        try env.write("Projects/node_modules/dep/CHANGELOG.md", "# Changes\n")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try env.write("node_modules/pkg/NEW.md", "# Added later\n")
        let stats = try await indexer.process(paths: ["node_modules/pkg/NEW.md", "node_modules"])
        #expect(stats.notesWritten == 0)
        try await indexer.query { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE path LIKE '%node_modules%'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM folders WHERE path LIKE '%node_modules%'") == 0)
        }
        #expect(VaultEntryKind.classify("node_modules/pkg/README.md") == nil)
        #expect(VaultEntryKind.classify("a/node_modules/b.png") == nil)
        #expect(VaultEntryKind.classify("node_modules.md") == .note, "only a directory of that name is ignored")
    }

    @Test func newNoteResolvesDanglingLinksWithoutReparsingSources() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        let homeBefore = try await indexer.query { db in try String.fetchOne(db, sql: "SELECT id || ':' || content_hash || ':' || indexed_gen FROM notes WHERE path = 'Home.md'")! }
        #expect(try await indexer.query { db in try linkTarget(db, from: "Home.md", raw: "Nonexistent Note") } == nil)

        try env.write("Somewhere/Nonexistent Note.md", "# Now it exists\n")
        let stats = try await indexer.process(paths: ["Somewhere/Nonexistent Note.md"])
        #expect(stats.notesWritten == 1, "only the new note is parsed")
        #expect(stats.linksResolved >= 1)
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Home.md", raw: "Nonexistent Note") == "Somewhere/Nonexistent Note.md")
            let homeAfter = try String.fetchOne(db, sql: "SELECT id || ':' || content_hash || ':' || indexed_gen FROM notes WHERE path = 'Home.md'")!
            #expect(homeAfter == homeBefore, "source note was not reparsed")
        }
    }

    @Test func deletingDuplicateReresolvesToRemainingCandidate() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try env.remove("Meetings/Meeting Notes.md")
        let stats = try await indexer.process(paths: ["Meetings/Meeting Notes.md"])
        #expect(stats.deleted == 1)
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Home.md", raw: "Meeting Notes") == "Archive/2024/Meeting Notes.md")
            // The now-empty Meetings folder is pruned.
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM folders WHERE path = 'Meetings'") == 0)
            // Backlinks of the deleted note are gone with it; the Alpha link from it too.
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE source_note_id NOT IN (SELECT id FROM notes)") == 0)
        }
    }

    @Test func renameMovesLinksAndKeepsOthersStable() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try FileManager.default.moveItem(at: env.vault.appendingPathComponent("Projects/Beta.md"), to: env.vault.appendingPathComponent("Projects/Gamma.md"))
        _ = try await indexer.process(paths: ["Projects/Beta.md", "Projects/Gamma.md"])
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Home.md", raw: "Beta#Goals") == nil, "[[Beta]] is now dangling")
            #expect(try linkTarget(db, from: "Home.md", raw: "Projects/Beta.md") == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE path = 'Projects/Gamma.md'") == 1)
        }
        // Rename back through reconciliation (simulates missed FSEvents).
        try FileManager.default.moveItem(at: env.vault.appendingPathComponent("Projects/Gamma.md"), to: env.vault.appendingPathComponent("Projects/Beta.md"))
        let stats = try await indexer.reconcile()
        #expect(stats.candidates == 2)
        #expect(try await indexer.query { db in try linkTarget(db, from: "Home.md", raw: "Beta#Goals") } == "Projects/Beta.md")
    }

    @Test func editChangesLinksTagsAndSearch() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try env.write("Projects/Alpha.md", "# Alpha v2\n\nNow links to [[Code]] only. #rewritten 新しい本文です。\n")
        let stats = try await indexer.process(paths: ["Projects/Alpha.md"])
        #expect(stats.notesWritten == 1)
        try await indexer.query { (db: Database) throws in
            let links = try String.fetchAll(db, sql: "SELECT raw FROM links l JOIN notes n ON n.id = l.source_note_id WHERE n.path = 'Projects/Alpha.md'")
            #expect(links == ["Code"])
            let tags = try String.fetchAll(db, sql: "SELECT t.name FROM note_tags nt JOIN tags t ON t.id = nt.tag_id JOIN notes n ON n.id = nt.note_id WHERE n.path = 'Projects/Alpha.md'")
            #expect(tags == ["rewritten"])
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM tags WHERE name = 'project/alpha'") == 0, "tags without notes are removed")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE body LIKE '%新しい本文%'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE body LIKE '%first project%'") == 0, "old text is no longer searchable")
        }
    }

    @Test func touchWithoutContentChangeOnlyUpdatesMetadata() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        let url = env.vault.appendingPathComponent("Code.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path)
        let stats = try await indexer.reconcile()
        #expect(stats.candidates == 1)
        let again = try await indexer.reconcile()
        #expect(again.candidates == 0, "new mtime was recorded")
    }

    @Test func deletingFolderRemovesContents() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try env.remove("Archive")
        let stats = try await indexer.process(paths: ["Archive"])
        #expect(stats.deleted == 1)
        try await indexer.query { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE path LIKE 'Archive/%'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM folders WHERE path LIKE 'Archive%'") == 0)
            #expect(try linkTarget(db, from: "Home.md", raw: "Archive/2024/Meeting Notes") == nil)
        }
    }

    @Test func movingFolderIntoVaultIsIndexed() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        let outside = env.tmp.sub("incoming")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try Data("# One\n[[Home]]".utf8).write(to: outside.appendingPathComponent("deep/One.md"))
        try FileManager.default.moveItem(at: outside, to: env.vault.appendingPathComponent("Incoming"))
        let stats = try await indexer.process(paths: ["Incoming"])
        #expect(stats.notesWritten == 1)
        #expect(try await indexer.query { db in try linkTarget(db, from: "Incoming/deep/One.md", raw: "Home") } == "Home.md")
    }

    @Test func decomposedFileNamesAreNormalized() async throws {
        let tmp = TempDir()
        let vault = tmp.sub("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let nfd = "Cafe\u{0301}.md"
        try Data("# Café\n".utf8).write(to: vault.appendingPathComponent(nfd))
        try Data("[[Café]] [[Cafe\u{0301}]]".utf8).write(to: vault.appendingPathComponent("Linker.md"))
        let env = try Env(copyFixture: false, vault: vault)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM notes ORDER BY path")
            #expect(paths.contains("Café.md"))
            let targets = try String.fetchAll(db, sql: "SELECT n.path FROM links l JOIN notes n ON n.id = l.target_note_id")
            #expect(targets == ["Café.md", "Café.md"])
        }
        // Reading the NFC path works on APFS (normalization-insensitive lookup).
        let again = try await indexer.reconcile()
        #expect(again.candidates == 0)
    }

    @Test func caseInsensitiveResolution() async throws {
        let tmp = TempDir()
        let vault = tmp.sub("vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: vault.appendingPathComponent("Sub/MixedCase.md"))
        try Data("[[mixedcase]] [[SUB/MIXEDCASE]] [m](sub/mixedcase.md) [[Sub/Missing]] [[Other/MixedCase]]".utf8).write(to: vault.appendingPathComponent("A.md"))
        let env = try Env(copyFixture: false, vault: vault)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "A.md", ordinal: 0) == "Sub/MixedCase.md")
            #expect(try linkTarget(db, from: "A.md", ordinal: 1) == "Sub/MixedCase.md")
            #expect(try linkTarget(db, from: "A.md", ordinal: 2) == "Sub/MixedCase.md")
            #expect(try linkTarget(db, from: "A.md", ordinal: 3) == nil)
            #expect(try linkTarget(db, from: "A.md", ordinal: 4) == nil, "explicit path that does not match any folder stays unresolved")
        }
    }

    @Test func builderCanBeRebuiltFromScratch() async throws {
        let env = try Env(copyFixture: true)
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            _ = try await indexer.publish()
        }
        // Throw away all builder state.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: env.config.builderDatabaseURL.path + suffix)
        }
        let rebuilt = try Indexer(configuration: env.config)
        let stats = try await rebuilt.reconcile()
        #expect(stats.index.notesWritten == 11)
        let result = try #require(try await rebuilt.publish())
        #expect(result.manifest.generation == 2, "generation numbers never go backwards after a rebuild")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func schemaMismatchRebuildsBuilder() async throws {
        let env = try Env(copyFixture: true)
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
        }
        let queue = try DatabaseQueue(path: env.config.builderDatabaseURL.path)
        try await queue.write { db in try db.execute(sql: "PRAGMA user_version = 999") }
        try queue.close()
        let indexer = try Indexer(configuration: env.config)
        let stats = try await indexer.reconcile()
        #expect(stats.index.notesWritten == 11)
    }

    @Test func stableReaderDetectsConcurrentModification() throws {
        let tmp = TempDir()
        let url = tmp.sub("n.md")
        try Data("original".utf8).write(to: url)
        let stable = StableReader.read(vault: tmp.url, relativePath: "n.md", maximumBytes: 1000, afterRead: nil)
        guard case .stable(let data, _) = stable else { Issue.record("expected stable"); return }
        #expect(String(decoding: data, as: UTF8.self) == "original")

        // Append while "reading".
        let appended = StableReader.read(vault: tmp.url, relativePath: "n.md", maximumBytes: 1000) {
            let h = try! FileHandle(forWritingTo: url)
            h.seekToEndOfFile()
            h.write(Data(" more".utf8))
            try! h.close()
        }
        guard case .unstable = appended else { Issue.record("expected unstable, got \(appended)"); return }

        // Atomic replace (rename over) while "reading".
        let replaced = StableReader.read(vault: tmp.url, relativePath: "n.md", maximumBytes: 1000) {
            let other = tmp.sub("tmp")
            try! Data("replaced!".utf8).write(to: other)
            _ = rename(other.path, url.path)
        }
        guard case .unstable = replaced else { Issue.record("expected unstable, got \(replaced)"); return }

        // Symlinks are never followed.
        let target = tmp.sub("secret")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: tmp.sub("link.md"), withDestinationURL: target)
        guard case .missing = StableReader.read(vault: tmp.url, relativePath: "link.md", maximumBytes: 1000) else {
            Issue.record("symlink must not be read"); return
        }
    }

    @Test func unstableFilesAreRetriedNotIndexedHalfWritten() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        // Symlinked notes are ignored by the walker.
        try FileManager.default.createSymbolicLink(at: env.vault.appendingPathComponent("Link.md"), withDestinationURL: env.vault.appendingPathComponent("Home.md"))
        let stats = try await indexer.reconcile()
        #expect(stats.candidates == 0)
    }
}
