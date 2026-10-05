import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

/// Cluster summaries, open questions and gaps (#39).
@Suite(.serialized) struct GraphLensTests {
    func env() throws -> (Env, URL) {
        var env = try Env(copyFixture: true)
        let extras = env.tmp.sub("extras")
        try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: true)
        env.config.extrasDirectory = extras
        env.config.graph.resolution = 1 // the fixture's clusters (see build_demo_artifact.sh)
        return (env, extras)
    }

    struct Export: Decodable {
        struct Cluster: Decodable {
            struct Member: Decodable { var path: String; var title: String }
            var id: Int64
            var label: String
            var members: [Member]
        }
        var clusters: [Cluster]
    }

    @Test func clustersAreExportedAndNotesAndGapsImported() async throws {
        let (env, extras) = try env()
        let indexer = try Indexer(configuration: env.config)
        let builder = await indexer.builder
        _ = try await indexer.reconcile()
        _ = try #require(try await indexer.publish())

        // The export names each cluster's most linked notes.
        let exportURL = env.config.stateDirectory.appendingPathComponent("graph-clusters.json")
        let export = try JSONDecoder().decode(Export.self, from: Data(contentsOf: exportURL))
        let big = try #require(export.clusters.first)
        #expect(big.members.map(\.path).contains("Projects/Beta.md"))
        let other = try #require(export.clusters.last)

        let notes = """
        {"clusters": [
          {"id": \(big.id), "members": \(try String(decoding: JSONEncoder().encode(big.members.map(\.path)), as: UTF8.self)),
           "summary": "プロジェクトの話", "questions": ["次は何か"], "generated_at": "2026-10-04"},
          {"id": \(other.id), "members": ["Gone.md", "Also gone.md"], "summary": "古い要約", "questions": []},
          {"id": 9999, "summary": "存在しないクラスタ", "questions": ["x"]}
        ]}
        """
        try Data(notes.utf8).write(to: extras.appendingPathComponent("cluster-notes.json"))
        let gaps = """
        {"gaps": [
          {"title": "Alpha と日本語", "sides": ["[[Alpha]]", "東京メモ"], "detail": "理由", "recommendations": ["Paper A — 検証済み"], "verdict": "real-gap", "report": "Home.md"},
          {"title": "片側が無い", "sides": ["Alpha", "Nowhere"]},
          {"title": "片側だけ", "sides": ["Alpha"]}
        ]}
        """
        try Data(gaps.utf8).write(to: extras.appendingPathComponent("gaps.json"))
        #expect(await indexer.checkExtras())
        _ = try #require(try await indexer.publish())

        let rows = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT cluster_id, summary, questions, stale FROM graph_cluster_notes ORDER BY cluster_id")
                .map { [String($0["cluster_id"] as Int64), $0["summary"] as String? ?? "", $0["questions"] as String, String($0["stale"] as Int)] }
        }
        #expect(rows.count == 2, "a cluster that does not exist is skipped")
        #expect(rows.contains([String(big.id), "プロジェクトの話", #"["次は何か"]"#, "0"]))
        #expect(rows.contains { $0[0] == String(other.id) && $0[3] == "1" }, "members gone: stale")

        let gapRows = try await builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT title, note_a, note_b, cluster_a, cluster_b, report_note_id FROM graph_gaps ORDER BY id")
                .map { ($0["title"] as String, $0["note_a"] as Int64?, $0["note_b"] as Int64?, $0["cluster_a"] as Int64?, $0["cluster_b"] as Int64?, $0["report_note_id"] as Int64?) }
        }
        #expect(gapRows.map(\.0) == ["Alpha と日本語", "片側が無い"])
        #expect(gapRows[0].1 != nil && gapRows[0].2 != nil && gapRows[0].5 != nil)
        #expect(gapRows[0].3 != nil && gapRows[0].4 != nil && gapRows[0].3 != gapRows[0].4, "the two sides are in different clusters")
        #expect(gapRows[1].2 == nil)

        // Removing the files empties the tables.
        try FileManager.default.removeItem(at: extras.appendingPathComponent("cluster-notes.json"))
        try FileManager.default.removeItem(at: extras.appendingPathComponent("gaps.json"))
        #expect(await indexer.checkExtras())
        _ = try await indexer.publish()
        let counts = try await builder.writer.read { db in
            [try Int.fetchOne(db, sql: "SELECT count(*) FROM graph_cluster_notes"), try Int.fetchOne(db, sql: "SELECT count(*) FROM graph_gaps")]
        }
        #expect(counts == [0, 0])
    }
}
