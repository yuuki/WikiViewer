import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

struct GraphLensRepositoryTests {
    @Test func clusterNotesAndGapsAreRead() async throws {
        let tmp = TempDir()
        let manifest = try makeArtifact(at: tmp.url, generation: 3) { db in
            let clusters = try Int64.fetchAll(db, sql: "SELECT id FROM graph_clusters ORDER BY size DESC")
            func id(_ path: String) throws -> Int64 { try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [path])! }
            try db.execute(sql: "INSERT INTO graph_cluster_notes VALUES (?, '要約', '[\"問い1\",\"問い2\"]', '2026-10-04', 0)", arguments: [clusters[0]])
            try db.execute(sql: """
                INSERT INTO graph_gaps(id, note_a, note_b, cluster_a, cluster_b, title, detail, recommendations, verdict, report_note_id)
                VALUES (1, ?, ?, ?, ?, '間', '理由', '["Paper"]', 'real-gap', ?),
                       (2, ?, NULL, ?, NULL, '片側', '', '[]', NULL, NULL)
                """, arguments: [try id("Projects/Alpha.md"), try id("Daily/2026-09-24.md"), clusters[0], clusters[1], try id("Home.md"),
                                 try id("Projects/Beta.md"), clusters[0]])
        }
        let database = try ViewerDatabase(url: tmp.url.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
        let graph = GraphRepository(database: database)
        let overview = try await graph.overview()
        let big = try #require(overview.clusters.first)
        let note = try #require(try await graph.clusterNote(id: big.id))
        #expect(note.summary == "要約")
        #expect(note.questions == ["問い1", "問い2"])
        #expect(!note.isStale)
        #expect(try await graph.clusterNote(id: overview.clusters[1].id) == nil)

        let touching = try await graph.gaps(touching: big.id)
        #expect(touching.map(\.title) == ["間", "片側"])
        #expect(touching[0].noteA?.path == "Projects/Alpha.md")
        #expect(touching[0].report?.path == "Home.md")
        #expect(touching[0].recommendations == ["Paper"])
        #expect(touching[0].crossesClusters)
        #expect(!touching[1].crossesClusters)
        #expect(try await graph.crossClusterGaps().map(\.id) == [1])
        #expect(try await graph.gaps(touching: overview.clusters[1].id).map(\.id) == [1])
    }
}
