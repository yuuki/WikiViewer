import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct FixtureIndexTests {
    @Test func indexesFixtureWithoutTouchingVault() async throws {
        let before = try treeSnapshot(fixtureVault)
        var env = try Env(copyFixture: false)
        env.config.fullIntegrityCheck = true
        let indexer = try Indexer(configuration: env.config)
        let stats = try await indexer.reconcile()
        #expect(stats.index.notesWritten == 11)
        #expect(stats.index.assetsWritten == 4, "three images and Notes.base")
        #expect(stats.index.unstable.isEmpty)
        let result = try #require(try await indexer.publish())
        #expect(result.manifest.noteCount == 11)
        let after = try treeSnapshot(fixtureVault)
        #expect(before == after, "the vault must never be modified")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func excludesHiddenAndUnsupportedFiles() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        let paths = try await indexer.query { (db: Database) throws in try String.fetchAll(db, sql: "SELECT path FROM notes UNION ALL SELECT path FROM assets ORDER BY 1") }
        #expect(!paths.contains { $0.hasPrefix(".") || $0.contains("/.") })
        #expect(!paths.contains("Board.canvas"))
        #expect(paths.contains("Café/Ünïcode Nöte.md"))
        #expect(paths.contains("日本語/東京メモ.md"))
    }

    @Test func linkResolution() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            let home = "Home.md"
            #expect(try linkTarget(db, from: home, raw: "Projects/Alpha") == "Projects/Alpha.md")
            #expect(try linkTarget(db, from: home, raw: "Alpha|Alpha project") == "Projects/Alpha.md")
            #expect(try linkTarget(db, from: home, raw: "Beta#Goals") == "Projects/Beta.md")
            #expect(try linkTarget(db, from: home, raw: "Beta#^decision-1") == "Projects/Beta.md")
            #expect(try linkTarget(db, from: home, raw: "Meeting Notes") == "Meetings/Meeting Notes.md", "shortest path wins for duplicate basenames")
            #expect(try linkTarget(db, from: home, raw: "Archive/2024/Meeting Notes") == "Archive/2024/Meeting Notes.md")
            #expect(try linkTarget(db, from: home, raw: "Nonexistent Note") == nil)
            #expect(try linkTarget(db, from: home, raw: "#Embeds") == "Home.md")
            #expect(try linkTarget(db, from: home, raw: "Projects/Beta.md") == "Projects/Beta.md")
            #expect(try linkTarget(db, from: home, raw: "./Daily/2026-09-24.md") == "Daily/2026-09-24.md")
            #expect(try linkTarget(db, from: home, raw: "diagram.png") == "attachments/diagram.png")
            #expect(try linkTarget(db, from: home, raw: "photo.jpg|400") == "attachments/photo.jpg")
            #expect(try linkTarget(db, from: home, raw: "Projects/Alpha#Summary") == "Projects/Alpha.md")

            let daily = "Daily/2026-09-24.md"
            #expect(try linkTarget(db, from: daily, raw: "Café/Ünïcode Nöte") == "Café/Ünïcode Nöte.md")
            #expect(try linkTarget(db, from: daily, raw: "../Café/Ünïcode%20Nöte.md") == "Café/Ünïcode Nöte.md")
            #expect(try linkTarget(db, from: daily, raw: "../attachments/diagram.png") == "attachments/diagram.png")

            #expect(try linkTarget(db, from: "日本語/東京メモ.md", raw: "ホーム") == nil, "aliases do not resolve links")
            #expect(try linkTarget(db, from: "Café/Ünïcode Nöte.md", raw: "東京メモ") == "日本語/東京メモ.md")
            #expect(try linkTarget(db, from: "Projects/Alpha.md", raw: "Beta\\|beta in table") == "Projects/Beta.md")

            // External links are not stored; code and comments contribute nothing.
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE raw LIKE 'http%'") == 0)
            let codeLinks = try String.fetchAll(db, sql: "SELECT l.raw FROM links l JOIN notes n ON n.id = l.source_note_id WHERE n.path = 'Code.md'")
            #expect(codeLinks == ["Home"])

            // Link metadata.
            let row = try #require(try Row.fetchOne(db, sql: "SELECT l.* FROM links l JOIN notes n ON n.id = l.source_note_id WHERE n.path = 'Home.md' AND l.raw = 'Beta#^decision-1'"))
            #expect(row["block_id"] == "decision-1")
            #expect(row["target_path"] == "Beta")
            let embed = try #require(try Row.fetchOne(db, sql: "SELECT l.* FROM links l JOIN notes n ON n.id = l.source_note_id WHERE n.path = 'Home.md' AND l.raw = 'photo.jpg|400'"))
            #expect(embed["is_embed"] == true)
            #expect(embed["display"] == "400")
        }
    }

    @Test func metadata() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            func tags(_ path: String) throws -> [String] {
                try String.fetchAll(db, sql: "SELECT t.name FROM note_tags nt JOIN tags t ON t.id = nt.tag_id JOIN notes n ON n.id = nt.note_id WHERE n.path = ? ORDER BY t.name", arguments: [path])
            }
            #expect(try tags("Home.md") == ["index", "inline-tag", "日本語"])
            #expect(try tags("Projects/Beta.md") == ["project/beta"])
            #expect(try tags("Projects/Alpha.md") == ["project", "project/alpha"])
            #expect(try tags("Code.md") == [])
            #expect(try tags("Daily/2026-09-24.md") == ["daily"])
            // 日本語 appears in two notes, case/Unicode-insensitive tag table.
            #expect(try Int.fetchOne(db, sql: "SELECT note_count FROM tags WHERE name = '日本語'") == 2)

            let aliases = try String.fetchAll(db, sql: "SELECT alias FROM aliases a JOIN notes n ON n.id = a.note_id WHERE n.path = 'Home.md' ORDER BY alias")
            #expect(aliases == ["Start", "ホーム"])
            #expect(try String.fetchAll(db, sql: "SELECT alias FROM aliases a JOIN notes n ON n.id = a.note_id WHERE n.path = 'Projects/Alpha.md'") == ["Alpha Project"])

            let fm = try #require(try String.fetchOne(db, sql: "SELECT frontmatter FROM notes WHERE path = 'Home.md'"))
            #expect(fm == #"[["aliases",["Start","ホーム"]],["tags",["index","日本語"]],["created","2026-09-24"],["rating",5],["draft",false]]"#)
            #expect(try String.fetchOne(db, sql: "SELECT frontmatter FROM notes WHERE path = 'Invalid YAML.md'") == nil)
            #expect(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE path = 'Invalid YAML.md'")?.contains("Body still indexed") == true)
            #expect(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE path = 'Home.md'")?.hasPrefix("# Home") == true)

            let headings = try String.fetchAll(db, sql: "SELECT h.text FROM headings h JOIN notes n ON n.id = h.note_id WHERE n.path = 'Projects/Beta.md' ORDER BY ordinal")
            #expect(headings == ["Beta", "Goals", "決定事項"])
            let blocks = try String.fetchAll(db, sql: "SELECT b.block_id FROM blocks b JOIN notes n ON n.id = b.note_id WHERE n.path = 'Projects/Beta.md'")
            #expect(blocks == ["decision-1"])

            // Folders: lazily expandable tree with counts; root is id 1.
            let top = try String.fetchAll(db, sql: "SELECT name FROM folders WHERE parent_id = 1 ORDER BY name")
            #expect(top == ["Archive", "attachments", "Café", "Daily", "Meetings", "Projects", "日本語"])
            #expect(try Int.fetchOne(db, sql: "SELECT note_count FROM folders WHERE id = 1") == 4)
            #expect(try Int.fetchOne(db, sql: "SELECT folder_count FROM folders WHERE path = 'Archive'") == 1)
        }
    }

    @Test func assetsAreContentAddressedAndDownsampled() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try await indexer.query { (db: Database) throws in
            let rows = try Row.fetchAll(db, sql: "SELECT path, source_sha256, blob_sha256, blob_ext, width, height FROM assets WHERE kind = 0 ORDER BY path")
            #expect(rows.count == 3)
            let diagram = rows.first { $0["path"] == "attachments/diagram.png" }!
            let copy = rows.first { $0["path"] == "attachments/copy of diagram.png" }!
            #expect(diagram["blob_sha256"] as String? == copy["blob_sha256"] as String?, "identical content is stored once")
            #expect(diagram["blob_sha256"] as String? == diagram["source_sha256"] as String?, "small PNGs pass through unchanged")
            let photo = rows.first { $0["path"] == "attachments/photo.jpg" }!
            #expect(photo["blob_ext"] == "jpg")
            // 3000x2000 stored with EXIF orientation 6 → displayed 2000x3000 → longest side 2048.
            #expect(photo["width"] as Int? == 1365)
            #expect(photo["height"] as Int? == 2048)
            #expect(photo["blob_sha256"] as String? != photo["source_sha256"] as String?)
        }
        let store = env.config.assetStoreURL
        let files = try FileManager.default.subpathsOfDirectory(atPath: store.path).filter { $0.contains(".") }
        #expect(files.count == 2)
    }

    @Test func fullTextSearchJapaneseAndEnglish() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            // detail='none' trigram index: substring LIKE on the FTS table.
            func search(_ q: String) throws -> [String] {
                try String.fetchAll(db, sql: "SELECT n.path FROM notes_fts f JOIN notes n ON n.id = f.rowid WHERE f.body LIKE ? ORDER BY n.path", arguments: ["%" + q + "%"])
            }
            #expect(try search("東京都") == ["日本語/東京メモ.md"])
            #expect(try search("全文検索") == ["日本語/東京メモ.md"])
            #expect(try search("trigram") == ["Projects/Beta.md"])
            #expect(try search("TRIGRAM") == ["Projects/Beta.md"], "ASCII case-insensitive")
            #expect(try search("データベース") == ["日本語/東京メモ.md"])
            let detail = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT rowid FROM notes_fts WHERE body LIKE '%trigram%'").map { $0["detail"] as String }.joined()
            #expect(detail.contains(":L"), "LIKE is answered from the trigram index: \(detail)")
        }
    }

    @Test func refusesUnsafeLocations() throws {
        let tmp = TempDir()
        let vault = tmp.sub("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let inside = IndexerConfiguration(vault: vault, stateDirectory: vault.appendingPathComponent("state"), publishDirectory: tmp.sub("pub"))
        #expect(throws: IndexerError.self) { try inside.validate() }
        let publishInside = IndexerConfiguration(vault: vault, stateDirectory: tmp.sub("state"), publishDirectory: vault.appendingPathComponent(".wiki"))
        #expect(throws: IndexerError.self) { try publishInside.validate() }
        let vaultInside = IndexerConfiguration(vault: vault, stateDirectory: tmp.url, publishDirectory: tmp.sub("pub"))
        #expect(throws: IndexerError.self) { try vaultInside.validate() }
        let ok = IndexerConfiguration(vault: vault, stateDirectory: tmp.sub("state"), publishDirectory: tmp.sub("pub"))
        try ok.validate()
    }
}
