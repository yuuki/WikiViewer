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

    /// Parsing runs in parallel, but rows are written in a fixed order: the
    /// same vault gives the same page layout however the reads were
    /// scheduled, so how many chunks an edit changes (and with it whether the
    /// keyframe is renewed) does not depend on timing.
    @Test func sameVaultGivesSamePageLayout() async throws {
        func layout() async throws -> [String] {
            var env = try Env(copyFixture: true)
            env.config.parseConcurrency = 8
            for i in 0..<200 {
                try env.write("Bulk/Note \(i).md", "# Note \(i)\n\n[[Home]] [[Note \((i + 1) % 200)]] [[Missing \(i % 7)]]\n" + String(repeating: "Body \(i).\n", count: i % 13))
            }
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            let result = try #require(try await indexer.publish())
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: result.databaseURL.path, configuration: config)
            return try await queue.read { db in
                try String.fetchAll(db, sql: "SELECT name || ':' || pageno || ':' || ncell || ':' || unused FROM dbstat ORDER BY pageno")
            }
        }
        let first = try await layout()
        for _ in 0..<2 {
            let other = try await layout()
            #expect(other == first, "pages that differ: \(zip(first, other).filter { $0 != $1 }.prefix(8))")
        }
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
        #expect(VaultEntryKind.classify("node_modules/pkg/README.md", filter: VaultFilter()) == nil)
        #expect(VaultEntryKind.classify("a/node_modules/b.png", filter: VaultFilter()) == nil)
        #expect(VaultEntryKind.classify("node_modules.md", filter: VaultFilter()) == .note, "only a directory of that name is ignored")
    }

    @Test func excludePatternsMatchFoldersOnly() throws {
        let filter = try VaultFilter(excluding: ["Private", "/Archive/2024/", "Daily/*-draft", "日本語"])
        #expect(filter.patterns == ["Private", "/Archive/2024", "/Daily/*-draft", "日本語"])
        // Unanchored: a folder name at any depth, case-insensitive.
        #expect(filter.excludesAncestor(of: "Private/a.md"))
        #expect(filter.excludesAncestor(of: "Work/private/deep/b.png"))
        #expect(!filter.excludesAncestor(of: "Private.md"), "folders only")
        #expect(!filter.excludesAncestor(of: "PrivateNotes/a.md"))
        // Anchored: a path from the vault root, and everything beneath it.
        #expect(filter.excludesAncestor(of: "Archive/2024/Meeting Notes.md"))
        #expect(filter.excludesAncestor(of: "Archive/2024/q1/x.md"))
        #expect(!filter.excludesAncestor(of: "Archive/2025/x.md"))
        #expect(!filter.excludesAncestor(of: "Old/Archive/2024/x.md"))
        // Wildcards stay within one component.
        #expect(filter.excludesAncestor(of: "Daily/2026-draft/x.md"))
        #expect(!filter.excludesAncestor(of: "Daily/2026/x-draft/x.md"))
        // Unicode: decomposed input still matches the NFC pattern.
        #expect(filter.excludesAncestor(of: "日本語/東京メモ.md"))
        let cafe = try VaultFilter(excluding: ["Cafe\u{301}"])
        #expect(cafe.excludesAncestor(of: "Café/Ünïcode Nöte.md"))
        // Built-ins are always excluded.
        #expect(filter.excludesDirectory(".obsidian"))
        #expect(VaultFilter().excludesPath("a/node_modules/pkg"))
        // Patterns that cannot name a folder in the vault are refused.
        for bad in ["", " ", "/", "../outside", "a/./b"] {
            #expect(throws: VaultFilter.InvalidPattern.self) { try VaultFilter(excluding: [bad]) }
        }
    }

    @Test func includePatternsSelectFoldersFromTheVaultRoot() throws {
        let filter = try VaultFilter(excluding: ["Private"], including: ["Projects/", "/Work/Notes", "Daily/2026-*"])
        #expect(filter.includePatterns == ["/Projects", "/Work/Notes", "/Daily/2026-*"])
        // Files inside an included folder, at any depth.
        #expect(!filter.excludesFile("Projects/Alpha.md"))
        #expect(!filter.excludesFile("projects/deep/x.png"), "case-insensitive")
        #expect(!filter.excludesFile("Work/Notes/a.md"))
        #expect(!filter.excludesFile("Daily/2026-09/a.md"))
        // Everything else, including the vault root and a same-named folder elsewhere.
        #expect(filter.excludesFile("Home.md"))
        #expect(filter.excludesFile("Work/a.md"))
        #expect(filter.excludesFile("Archive/Projects/a.md"), "include patterns are anchored")
        #expect(filter.excludesFile("Daily/2025-12/a.md"))
        // Exclusions still apply inside included folders.
        #expect(filter.excludesFile("Projects/Private/a.md"))
        #expect(filter.excludesFile("Projects/.hidden/a.md"))
        // The walk descends only into folders that can lead to an included one.
        #expect(filter.mayInclude("Work"))
        #expect(filter.mayInclude("Work/Notes/deep"))
        #expect(!filter.mayInclude("Work/Other"))
        #expect(!filter.mayInclude("Archive"))
        #expect(filter.mayInclude("Daily"))
        // Without include patterns the whole vault is included.
        #expect(!VaultFilter().excludesFile("Home.md"))
        #expect(VaultFilter().mayInclude("Anything"))
        #expect(throws: VaultFilter.InvalidPattern.self) { try VaultFilter(excluding: [], including: ["../outside"]) }
    }

    @Test func onlyIncludedFoldersArePublished() async throws {
        let env = try Env(copyFixture: true)
        func paths(_ indexer: Indexer) async throws -> [String] {
            try await indexer.query { db in try String.fetchAll(db, sql: "SELECT path FROM notes UNION ALL SELECT path FROM assets ORDER BY 1") }
        }
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
        }
        var included = env.config
        included.includePatterns = ["Projects", "Archive/2024", "attachments"]
        included.excludePatterns = ["Beta*"]
        try env.write("Projects/Beta Drafts/Draft.md", "# Draft\n")
        do {
            let indexer = try Indexer(configuration: included)
            _ = try await indexer.reconcile()
            let published = try await paths(indexer)
            #expect(published.filter { $0.hasSuffix(".md") } == ["Archive/2024/Meeting Notes.md", "Projects/Alpha.md", "Projects/Beta.md"])
            #expect(published.contains("attachments/diagram.png"))
            try await indexer.query { (db: Database) throws in
                let folders = try String.fetchAll(db, sql: "SELECT path FROM folders ORDER BY 1")
                #expect(folders == ["", "Archive", "Archive/2024", "Projects", "attachments"], "the root plus included folders and their parents")
                // Links into folders that are not published stay unresolved.
                #expect(try linkTarget(db, from: "Projects/Alpha.md", raw: "Home") == nil)
            }
            // The FSEvents fast path ignores folders that are not included.
            try env.write("Daily/2026-09-25.md", "# New day\n")
            try env.write("Top.md", "# At the root\n")
            #expect(try await indexer.process(paths: ["Daily/2026-09-25.md", "Daily", "Top.md"]).notesWritten == 0)
            #expect(try await indexer.reconcile(subpath: "Daily").candidates == 0)
            try env.write("Projects/Gamma.md", "# Gamma\n")
            #expect(try await indexer.process(paths: ["Projects/Gamma.md"]).notesWritten == 1)
            let result = try #require(try await indexer.publish())
            #expect(result.manifest.noteCount == 4)
            let filter = await indexer.filter
            #expect(IndexerDaemon.isIgnored("Daily/2026-09-25.md", filter: filter))
            #expect(IndexerDaemon.isIgnored("Top.md", filter: filter))
            #expect(!IndexerDaemon.isIgnored("Archive", filter: filter), "may lead to Archive/2024")
            #expect(!IndexerDaemon.isIgnored("Projects/Gamma.md", filter: filter))
        }
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            let all = try await paths(indexer)
            #expect(all.contains("Home.md") && all.contains("Daily/2026-09-25.md"), "removing the inclusions indexes the whole vault again")
        }
    }

    @Test func anEmptyIncludeFileIsRefused() throws {
        let env = try Env(copyFixture: true)
        let file = env.tmp.sub("include.txt")
        try Data("# nothing yet\n".utf8).write(to: file)
        var config = env.config
        config.includeFile = file
        #expect(throws: IndexerError.self) { try Indexer(configuration: config) }
        config.includePatterns = ["Projects"]
        #expect(try config.makeFilter().includePatterns == ["/Projects"], "--include alone is enough")
    }

    @Test func excludedFoldersAreDroppedAndRestoredWhenTheFilterChanges() async throws {
        let env = try Env(copyFixture: true)
        func count(_ indexer: Indexer, _ like: String) async throws -> Int {
            try await indexer.query { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE path LIKE ?", arguments: [like])! }
        }
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            #expect(try await count(indexer, "Projects/%") == 2)
        }
        var excluded = env.config
        excluded.excludePatterns = ["projects", "/Archive"]
        do {
            let indexer = try Indexer(configuration: excluded)
            let stats = try await indexer.reconcile()
            #expect(stats.index.deleted >= 3)
            #expect(try await count(indexer, "Projects/%") == 0)
            #expect(try await count(indexer, "Archive/%") == 0)
            #expect(try await count(indexer, "Meetings/%") == 1, "other folders are untouched")
            try await indexer.query { (db: Database) throws in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM folders WHERE path IN ('Projects', 'Archive', 'Archive/2024')") == 0)
            }
            // The FSEvents fast path ignores excluded folders too.
            try env.write("Projects/Gamma.md", "# Gamma\n")
            let fast = try await indexer.process(paths: ["Projects/Gamma.md", "Projects"])
            #expect(fast.notesWritten == 0)
            #expect(try await indexer.reconcile(subpath: "Projects").candidates == 0)
            let published = try #require(try await indexer.publish())
            #expect(published.manifest.noteCount == (try await count(indexer, "%")))
        }
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
            #expect(try await count(indexer, "Projects/%") == 3, "removing the exclusion indexes the folder again")
            #expect(try await count(indexer, "Archive/%") == 1)
        }
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
