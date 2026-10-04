import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

/// What each generation changed (#36): change_log, generation_log and the
/// vault's operation log.
@Suite(.serialized) struct ChangeLogTests {
    struct Change: Equatable {
        var generation: Int64
        var path: String
        var kind: Int
        var type: String?
        var author: Int
    }

    func changes(_ builder: BuilderDatabase) async throws -> [Change] {
        try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM change_log ORDER BY generation, path").map {
                Change(generation: $0["generation"], path: $0["path"], kind: $0["kind"], type: $0["type"], author: $0["author"])
            }
        }
    }

    static let log = """
    ## [2026-10-03] ingest-paper | First paper
    - Summary: [[Home]]
    - Pages created: [[Alpha]]
    """

    @Test func firstPublicationIsTheBaselineThenChangesAreRecordedByGeneration() async throws {
        let env = try Env(copyFixture: true)
        try env.write("wiki/log.md", Self.log)
        let indexer = try Indexer(configuration: env.config)
        let builder = await indexer.builder
        _ = try await indexer.reconcile()
        let first = try #require(try await indexer.publish())
        #expect(try await changes(builder).isEmpty, "indexing the whole vault is not news")
        #expect(try await builder.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM log_entries WHERE generation = 0") } == 1)

        try env.write("wiki/concepts/Paxos.md", "---\ntype: concept\naddress: c-000001\n---\n# Paxos\n")
        try env.write("Projects/Alpha.md", "# Alpha\n\nRewritten by hand.\n")
        try env.remove("Projects/Beta.md")
        try env.write("Scratch.md", "temporary")
        _ = try await indexer.reconcile()
        try env.remove("Scratch.md") // added and removed before publication: nothing
        try env.write("wiki/log.md", """
        ## [2026-10-04] ingest-paper | Second paper
        - Summary: [[Paxos]]
        - Pages updated: [[Alpha]], [[Missing]]
        \(Self.log)
        """)
        _ = try await indexer.reconcile()
        let second = try #require(try await indexer.publish())
        #expect(second.manifest.generation == first.manifest.generation + 1)
        let g = second.manifest.generation
        #expect(try await changes(builder) == [
            Change(generation: g, path: "Projects/Alpha.md", kind: ViewerSchema.ChangeKind.modified.rawValue, type: nil, author: Provenance.Author.human.rawValue),
            Change(generation: g, path: "Projects/Beta.md", kind: ViewerSchema.ChangeKind.removed.rawValue, type: nil, author: Provenance.Author.human.rawValue),
            Change(generation: g, path: "wiki/concepts/Paxos.md", kind: ViewerSchema.ChangeKind.added.rawValue, type: "concept", author: Provenance.Author.claude.rawValue),
            Change(generation: g, path: "wiki/log.md", kind: ViewerSchema.ChangeKind.modified.rawValue, type: nil, author: Provenance.Author.claude.rawValue),
        ])
        let counts = try await builder.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT added, modified, removed FROM generation_log WHERE generation = ?", arguments: [g])
                .map { [$0["added"] as Int, $0["modified"] as Int, $0["removed"] as Int] }
        }
        #expect(counts == [1, 2, 1])

        // Only the new log entry belongs to this generation; its pages are
        // the notes it links to that exist.
        let entries = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT generation, title, pages FROM log_entries ORDER BY id")
                .map { (generation: $0["generation"] as Int64, title: $0["title"] as String, pages: $0["pages"] as String) }
        }
        #expect(entries.map(\.title) == ["First paper", "Second paper"])
        #expect(entries.map(\.generation) == [0, g])
        let pages = try JSONSerialization.jsonObject(with: Data(entries[1].pages.utf8)) as? [[String]]
        #expect(pages == [["Paxos", "wiki/concepts/Paxos.md"], ["Alpha", "Projects/Alpha.md"]])

        // Nothing new: no rows for the next generation.
        try env.write("Projects/Gamma.md", "# Gamma")
        _ = try await indexer.reconcile()
        let third = try #require(try await indexer.publish())
        #expect(try await changes(builder).filter { $0.generation == third.manifest.generation }.map(\.path) == ["Projects/Gamma.md"])
        #expect(try await builder.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM log_entries") } == 2)
    }

    @Test func publishedSnapshotCarriesTheLogButNotThePendingChanges() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try env.write("New.md", "# New")
        _ = try await indexer.reconcile()
        let result = try #require(try await indexer.publish())
        let queue = try DatabaseQueue(path: env.config.publishDirectory.appendingPathComponent(result.manifest.database.path).path)
        let counts = try await queue.read { db in
            [try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log"), try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_changes")]
        }
        #expect(counts == [1, 0])
    }

    @Test func oldRowsAreDropped() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            for statement in ViewerSchema.createStatements { try db.execute(sql: statement) }
            try db.execute(sql: "INSERT INTO builder_state(key, value) VALUES ('change_log_baseline', '1')")
            let now = Date()
            let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-40 * 24 * 3600))
            try db.execute(sql: "INSERT INTO generation_log VALUES (1, ?, 1, 0, 0)", arguments: [old])
            try db.execute(sql: "INSERT INTO change_log VALUES (1, 'a.md', 0, 'a', NULL, 0)")
            try db.execute(sql: "INSERT INTO pending_changes VALUES ('b.md', 2)")
            try ChangeLog.record(db, generation: 2, now: now, configuration: ChangeLogConfiguration())
            #expect(try Int64.fetchAll(db, sql: "SELECT generation FROM change_log") == [2])
            #expect(try Int64.fetchAll(db, sql: "SELECT generation FROM generation_log") == [2])
        }
    }

    @Test func pendingChangesMerge() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            for statement in ViewerSchema.createStatements { try db.execute(sql: statement) }
            func kind(_ path: String) throws -> Int? { try Int.fetchOne(db, sql: "SELECT kind FROM pending_changes WHERE path = ?", arguments: [path]) }
            try ChangeLog.notePending(db, path: "a", kind: .added)
            try ChangeLog.notePending(db, path: "a", kind: .modified)
            #expect(try kind("a") == ViewerSchema.ChangeKind.added.rawValue)
            try ChangeLog.notePending(db, path: "a", kind: .removed)
            #expect(try kind("a") == nil)
            try ChangeLog.notePending(db, path: "b", kind: .removed)
            try ChangeLog.notePending(db, path: "b", kind: .added)
            #expect(try kind("b") == ViewerSchema.ChangeKind.modified.rawValue)
            try ChangeLog.notePending(db, path: "c", kind: .modified)
            try ChangeLog.notePending(db, path: "c", kind: .removed)
            #expect(try kind("c") == ViewerSchema.ChangeKind.removed.rawValue)
        }
    }

    @Test func logEntriesAreParsed() {
        let entries = ChangeLog.parseLog("""
        # Log
        ## [2026-10-04] ingest-paper | How to Write to SSDs
        - Source: `.raw/papers/p.pdf`
        - Summary: [[@2026__PVLDB__How to Write to SSDs]]
        ## [2026-10-03] revert-ingest | Distant papers
        - Summary: removed 36
        ## Not an entry
        text
        """)
        #expect(entries.map(\.date) == ["2026-10-04", "2026-10-03"])
        #expect(entries.map(\.operation) == ["ingest-paper", "revert-ingest"])
        #expect(entries.map(\.title) == ["How to Write to SSDs", "Distant papers"])
        #expect(entries[0].lines == 1..<4)
        #expect(entries[1].body == "- Summary: removed 36")
    }

    @Test func authorComesFromTheNote() {
        #expect(Provenance.author(path: "notes/a.md", fields: [:]) == .human)
        #expect(Provenance.author(path: "wiki/concepts/a.md", fields: [:]) == .claude)
        #expect(Provenance.author(path: "notes/a.md", fields: ["address": "c-000123"]) == .claude)
        #expect(Provenance.author(path: "notes/a.md", fields: ["address": "Tokyo"]) == .human)
        #expect(Provenance.author(path: "wiki/a.md", fields: ["author_kind": "human"]) == .human)
        #expect(Provenance.author(path: "notes/a.md", fields: ["provenance": "Claude"]) == .claude)
    }
}
