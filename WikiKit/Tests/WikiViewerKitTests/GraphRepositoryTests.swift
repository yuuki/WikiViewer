import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

/// The demo snapshot's graph: Home, the projects and the meeting notes form
/// one cluster; the daily note, the Japanese note and the Unicode note
/// another.
@Suite struct GraphRepositoryTests {
    let session: LibrarySession

    init() throws {
        session = LibrarySession(database: try openDemo(), installed: nil)
    }

    func id(_ path: String) async throws -> Int64 {
        try #require(try await session.notes.noteID(path: path))
    }

    @Test func overviewListsClustersLargestFirst() async throws {
        let overview = try await session.graph.overview()
        #expect(overview.clusterCount == 2)
        #expect(overview.nodeCount == 9)
        #expect(overview.clusters.map(\.size) == [6, 3])
        #expect(overview.clusters.first?.label == "Beta", "named after the most linked note")
        #expect(overview.links.count == 1)
        #expect(overview.links.first?.skeleton == true)
        let page = try await session.graph.clusters(limit: 1)
        #expect(page.hasMore)
        let next = try await session.graph.clusters(after: page.items.last, limit: 1)
        #expect(next.items.map(\.id) == [overview.clusters[1].id])
        #expect(!next.hasMore)
    }

    @Test func clusterGraphHasMembersEdgesAndNeighbours() async throws {
        let overview = try await session.graph.overview()
        let big = try #require(overview.clusters.first)
        let graph = try #require(try await session.graph.clusterGraph(id: big.id))
        #expect(graph.nodes.count == 6)
        #expect(!graph.isTruncated)
        #expect(graph.nodes.first?.path == "Projects/Beta.md", "most linked first")
        #expect(graph.nodes.allSatisfy { $0.x * $0.x + $0.y * $0.y <= 1.0003 })
        let ids = Set(graph.nodes.map(\.id))
        #expect(!graph.edges.isEmpty)
        #expect(graph.edges.allSatisfy { ids.contains($0.a) && ids.contains($0.b) && $0.a < $0.b })
        #expect(graph.neighbours.map(\.cluster.id) == [overview.clusters[1].id])
        let truncated = try #require(try await session.graph.clusterGraph(id: big.id, limit: 2))
        #expect(truncated.isTruncated)
        #expect(truncated.edges.allSatisfy { Set(truncated.nodes.map(\.id)).contains($0.a) })
    }

    @Test func nodesAndNeighbours() async throws {
        let home = try await id("Home.md")
        let node = try #require(try await session.graph.node(id: home))
        #expect(node.cluster != nil)
        #expect(try await session.graph.node(path: "Home.md")?.id == home)
        let empty = try #require(try await session.graph.node(path: "Empty.md"))
        #expect(empty.cluster == nil, "notes outside the graph still resolve")
        let neighbours = try await session.graph.neighbours(of: home)
        #expect(neighbours.contains { $0.node.path == "Projects/Alpha.md" })
        #expect(!neighbours.contains { $0.node.id == home })
    }

    @Test func localGraphRanksNeighboursAndShowsMissingNotes() async throws {
        let home = try await id("Home.md")
        let local = try #require(try await session.graph.localGraph(of: home))
        #expect(local.members.first?.node.id == home)
        #expect(local.members.first?.depth == 0)
        #expect(local.members.contains { $0.depth == 1 && $0.node.path == "Projects/Beta.md" })
        #expect(Set(local.members.map(\.id)).count == local.members.count)
        #expect(local.missing.contains("Nonexistent Note"))
        for m in local.members where m.depth == 2 {
            #expect(m.parent.map { p in local.members.contains { $0.id == p && $0.depth == 1 } } == true)
        }
    }

    @Test func typesAreListed() async throws {
        // The demo vault has no `type` properties.
        #expect(try await session.graph.types().isEmpty)
    }
}
