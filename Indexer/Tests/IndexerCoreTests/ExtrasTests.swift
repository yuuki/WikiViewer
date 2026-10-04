import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

/// Host-made extras imported at publication (#38).
@Suite(.serialized) struct ExtrasTests {
    struct Neighbour: Equatable {
        var note: String
        var role: String
        var rank: Int
        var target: String
    }

    func neighbours(_ builder: BuilderDatabase) async throws -> [Neighbour] {
        try await builder.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.path AS note, r.role, r.rank, t.path AS target FROM related r
                JOIN notes s ON s.id = r.note_id JOIN notes t ON t.id = r.target_note_id
                ORDER BY s.path, r.role, r.rank
                """).map { Neighbour(note: $0["note"], role: $0["role"], rank: $0["rank"], target: $0["target"]) }
        }
    }

    func env() throws -> (Env, URL) {
        var env = try Env(copyFixture: true)
        let extras = env.tmp.sub("extras")
        try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: true)
        env.config.extrasDirectory = extras
        return (env, extras)
    }

    func write(_ lines: [String], to extras: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: extras.appendingPathComponent("related.jsonl"))
    }

    @Test func relatedNeighboursAreImportedAndDiffed() async throws {
        let (env, extras) = try env()
        try write([
            #"{"seed": "Home.md", "roles": {"cluster": [{"page_path": "Code.md", "why": ""}], "definition": [{"page_path": "Projects/Alpha.md", "why": "接続: [[Alpha]]"}, {"page_path": "Missing.md"}, {"page_path": "Projects/Beta.md"}]}}"#,
            "not json",
            #"{"seed": "Nowhere.md", "roles": {"definition": [{"page_path": "Home.md"}]}}"#,
            #"{"seed": "Code.md", "roles": {"evidence": [{"page_path": "Code.md"}]}}"#,
        ], to: extras)
        let indexer = try Indexer(configuration: env.config)
        let builder = await indexer.builder
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())
        #expect(try await neighbours(builder) == [
            Neighbour(note: "Home.md", role: "cluster", rank: 0, target: "Code.md"),
            Neighbour(note: "Home.md", role: "definition", rank: 0, target: "Projects/Alpha.md"),
            Neighbour(note: "Home.md", role: "definition", rank: 2, target: "Projects/Beta.md"),
        ], "unknown notes, self-links and bad lines are skipped")
        let why = try await builder.writer.read { try String.fetchOne($0, sql: "SELECT why FROM related WHERE rank = 0 AND role = 'definition'") }
        #expect(why == "接続: [[Alpha]]")

        // Unchanged extras and vault: nothing to do.
        #expect(await indexer.checkExtras() == false)
        try await Task.sleep(for: .milliseconds(20))
        try write([#"{"seed": "Home.md", "roles": {"definition": [{"page_path": "Projects/Beta.md"}]}}"#], to: extras)
        #expect(await indexer.checkExtras(), "a changed file asks for a publication")
        #expect(await indexer.hasUnpublishedChanges)
        _ = try #require(try await indexer.publish())
        #expect(try await neighbours(builder) == [Neighbour(note: "Home.md", role: "definition", rank: 0, target: "Projects/Beta.md")])

        try FileManager.default.removeItem(at: extras.appendingPathComponent("related.jsonl"))
        #expect(await indexer.checkExtras())
        _ = try #require(try await indexer.publish())
        #expect(try await neighbours(builder).isEmpty, "no file, no neighbours")
    }

    @Test func recallQuestionsAreImportedNewestFirstAndBounded() async throws {
        let (env, extras) = try env()
        let recall = """
        {"items": [
          {"id": "q1", "note": "Projects/Alpha.md", "heading": "Summary", "question": "Alpha とは?", "answer": "最初のプロジェクト", "created": "2026-10-03"},
          {"id": "q2", "note": "Missing.md", "question": "?", "answer": "!", "created": "2026-10-04"},
          {"id": "", "note": "Home.md", "question": "?", "answer": "!", "created": "2026-10-04"}
        ]}
        """
        try Data(recall.utf8).write(to: extras.appendingPathComponent("recall.json"))
        let indexer = try Indexer(configuration: env.config)
        let builder = await indexer.builder
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        let rows = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, heading, question FROM recall_items").map { [$0["id"] as String, $0["heading"] as String? ?? "", $0["question"] as String] }
        }
        #expect(rows == [["q1", "Summary", "Alpha とは?"]], "unknown notes and empty ids are skipped")
    }

    @Test func extrasMustBeOutsideTheVault() throws {
        var env = try Env(copyFixture: true)
        env.config.extrasDirectory = env.vault.appendingPathComponent("extras")
        #expect(throws: IndexerError.self) { try env.config.validate() }
    }

    @Test func neighboursPerNoteAreBounded() async throws {
        let (env, extras) = try env()
        for i in 0..<20 { try env.write("N\(i).md", "# N\(i)") }
        let candidates = (0..<20).map { #"{"page_path": "N\#($0).md"}"# }.joined(separator: ", ")
        try write([#"{"seed": "Home.md", "roles": {"cluster": [\#(candidates)]}}"#], to: extras)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        #expect(try await neighbours(await indexer.builder).count == Extras.maximumRelatedPerNote)
    }
}
