import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct LeidenTests {
    /// Two 5-cliques joined by one link.
    static func barbell() -> WeightedGraph {
        WeightedGraph(nodeCount: 10, edges: cliques(2, size: 5) + [(4, 5, 1)])
    }

    static func cliques(_ count: Int, size: Int) -> [(a: Int, b: Int, weight: Double)] {
        var edges: [(a: Int, b: Int, weight: Double)] = []
        for k in 0..<count {
            let base = k * size
            for i in base..<(base + size) {
                for j in (i + 1)..<(base + size) { edges.append((i, j, 1)) }
            }
        }
        return edges
    }

    @Test func separatesCliques() {
        let graph = Self.barbell()
        let c = Leiden.communities(graph)
        #expect(Set(c[0..<5]).count == 1)
        #expect(Set(c[5..<10]).count == 1)
        #expect(c[0] != c[9])
        #expect(graph.modularity(c) > 0.4)
    }

    @Test func warmStartKeepsAGoodPartition() {
        let graph = Self.barbell()
        let first = Leiden.communities(graph)
        let again = Leiden.communities(graph, initial: first.map { $0 + 100 })
        #expect(again == first)
    }

    @Test func warmStartRepairsABadPartition() {
        let graph = Self.barbell()
        // Node 4 starts in the wrong clique.
        let initial = [0, 0, 0, 0, 1, 1, 1, 1, 1, 1]
        let c = Leiden.communities(graph, initial: initial)
        #expect(c[4] == c[0])
        #expect(c[5] == c[9])
    }

    /// Louvain cannot split a community it starts from: no single node
    /// gains by leaving. Leiden's refinement can.
    @Test func warmStartSplitsMergedCommunities() {
        let graph = Self.barbell()
        let c = Leiden.communities(graph, initial: Array(repeating: 0, count: 10))
        #expect(c[0] != c[9])
    }

    /// Six 6-cliques in a ring. Merging two neighbours gains
    /// 1 − γ·32·32/192, so below γ ≈ 0.19 they merge, above they stay apart.
    @Test func resolutionGivesSmallerCommunities() {
        var edges = Self.cliques(6, size: 6)
        for k in 0..<6 { edges.append((k * 6, ((k + 1) % 6) * 6 + 1, 1)) }
        let graph = WeightedGraph(nodeCount: 36, edges: edges)
        let coarse = Set(Leiden.converged(graph, initial: nil, resolution: 0.1)).count
        let fine = Set(Leiden.converged(graph, initial: nil, resolution: 1)).count
        #expect(coarse < fine)
        #expect(fine == 6)
    }

    /// Node 10 links to both cliques alike: it stays wherever it was.
    @Test func followingKeepsBorderlineNodesWhereTheyWere() {
        var edges = Self.cliques(2, size: 5)
        edges += [(10, 0, 1), (10, 1, 1), (10, 5, 1), (10, 6, 1)]
        let graph = WeightedGraph(nodeCount: 11, edges: edges)
        for side in [0, 1] {
            let previous: [Int?] = (0..<10).map { $0 < 5 ? 0 : 1 } + [side]
            let c = Leiden.following(graph, previous: previous, resolution: 1, coupling: 0.05)
            #expect(c[10] == c[side == 0 ? 0 : 9])
            #expect(c[0] != c[9])
        }
    }

    /// Coupling does not preserve a community that should not exist.
    @Test func followingStillSplitsMergedCommunities() {
        let graph = Self.barbell()
        let c = Leiden.following(graph, previous: Array(repeating: 7, count: 10), resolution: 1, coupling: 0.05)
        #expect(Set(c[0..<5]).count == 1)
        #expect(c[0] != c[9])
    }

    @Test func followingNothingStartsAfresh() {
        let graph = Self.barbell()
        let fresh = Leiden.converged(graph, initial: nil, resolution: 1)
        #expect(Leiden.following(graph, previous: nil, resolution: 1, coupling: 0.05) == fresh)
        #expect(Leiden.following(graph, previous: Array(repeating: nil, count: 10), resolution: 1, coupling: 0.05) == fresh)
    }

    /// Notes not clustered before join a community on their merits.
    @Test func followingPlacesNewNodes() {
        let graph = Self.barbell()
        let previous: [Int?] = [0, 0, 0, 0, nil, 1, 1, 1, 1, nil]
        let c = Leiden.following(graph, previous: previous, resolution: 1, coupling: 0.05)
        #expect(c[4] == c[0])
        #expect(c[9] == c[5])
    }
}

@Suite struct ForceLayoutTests {
    @Test func spreadsNodesAndStaysFinite() {
        let graph = LeidenTests.barbell()
        var positions = (0..<10).map { i in SIMD2(Double(i % 3), Double(i / 3)) }
        var edges: [ForceAtlas2.Edge] = []
        for i in 0..<10 {
            for e in graph.offsets[i]..<graph.offsets[i + 1] where i < Int(graph.neighbors[e]) {
                edges.append((i, Int(graph.neighbors[e]), 1))
            }
        }
        ForceAtlas2.run(positions: &positions, edges: edges, iterations: 300, settings: .inferred(nodeCount: 10))
        #expect(positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Each clique ends up nearer to itself than to the other.
        func centre(_ r: Range<Int>) -> SIMD2<Double> { r.map { positions[$0] }.reduce(.zero, +) / Double(r.count) }
        let a = centre(0..<5), b = centre(5..<10)
        let within = (positions[0] - a) * (positions[0] - a)
        let between = (a - b) * (a - b)
        #expect(within.sum() < between.sum())
    }

    @Test func barnesHutMatchesDirectRepulsionRoughly() {
        var rng = SplitMix64(state: 7)
        let n = 400
        let start = (0..<n).map { _ in SIMD2(Double(rng.next() % 1000), Double(rng.next() % 1000)) }
        var tree = QuadTree()
        tree.build(positions: start, mass: .init(repeating: 1, count: n))
        var direct = SIMD2<Double>.zero
        for j in 1..<n {
            let d = start[0] - start[j]
            direct += d / (d * d).sum()
        }
        let approx = tree.repulsion(on: 0, position: start[0], mass: 1, coefficient: 1, theta: 0.5)
        let error = ((approx - direct) * (approx - direct)).sum().squareRoot() / (direct * direct).sum().squareRoot()
        #expect(error < 0.1)
    }

    /// A hub with many notes and a single-link note that passes right by it:
    /// the repulsion between them is in the millions. Unbounded, that one
    /// step threw the note several times the layout's width away, and the
    /// normalization that followed squashed every other note onto a point.
    @Test func nearCollisionDoesNotThrowANodeAway() {
        let leaves = 300
        var positions = [SIMD2<Double>.zero]
        var edges: [ForceAtlas2.Edge] = []
        var rng = SplitMix64(state: 3)
        for k in 1...leaves {
            edges.append((0, k, 1))
            let angle = Double(rng.int(10_000)) / 10_000 * 2 * .pi
            positions.append(SIMD2(cos(angle), sin(angle)) * Double(50 + rng.int(150)))
        }
        // A note linked to one of the leaves, a hair's breadth from the hub.
        edges.append((1, positions.count, 1))
        positions.append(SIMD2(0.001, 0))
        let n = positions.count
        let settings = ForceAtlas2.Settings.inferred(nodeCount: n)
        ForceAtlas2.run(positions: &positions, edges: edges, iterations: 1, settings: settings)
        // It moves away from the hub, by at most a step (a tenth of the layout).
        let moved = (positions[n - 1] * positions[n - 1]).sum().squareRoot()
        #expect(moved > 0.001)
        #expect(moved < 2 * Double(n).squareRoot(), "moved \(moved)")
    }

    /// A hub and notes linked only to it.
    static func star(_ n: Int) -> (WeightedGraph, [GraphBuilder.Node]) {
        let edges = (1..<n).map { (a: 0, b: $0, weight: 1.0) }
        let nodes = (0..<n).map { GraphBuilder.Node(id: Int64($0 + 1), title: "\($0)", type: nil, status: nil) }
        return (WeightedGraph(nodeCount: n, edges: edges), nodes)
    }

    /// A layout that diverged before steps were bounded is laid out afresh,
    /// even if the cluster did not change.
    @Test func divergedLayoutIsReplaced() {
        let n = 300
        let (graph, nodes) = Self.star(n)
        let members = Array(0..<n)
        let clusterOf = [Int64?](repeating: 1, count: n)
        let fresh = GraphBuilder.layoutCluster(id: 1, members: members, graph: graph, clusterOf: clusterOf, nodes: nodes,
                                               previous: .init(), previousLayout: nil)
        // Everything but one far note on the same point.
        let collapsed = (0..<n).map { $0 == 0 ? SIMD2(1.0, 0) : SIMD2(0.0003, 0.0033) }
        var previous = GraphBuilder.Rows()
        for (k, node) in nodes.enumerated() {
            previous.nodes[node.id] = .init(cluster: 1, x: collapsed[k].x, y: collapsed[k].y, weight: 0, degree: 0, type: nil, status: nil)
        }
        let result = GraphBuilder.layoutCluster(id: 1, members: members, graph: graph, clusterOf: clusterOf, nodes: nodes,
                                                previous: previous, previousLayout: .init(digest: fresh.1.digest, scale: 1.9e27))
        #expect(result.2)
        #expect(result.1.scale < 3 * 10 * Double(n).squareRoot())
        #expect(Set(result.0).count > n * 9 / 10)
    }
}

@Suite struct GraphBuilderTests {
    /// Two topics of five notes that link among themselves, one note that
    /// bridges them, and an index that links to everything.
    static func writeVault(_ env: Env) throws {
        for topic in ["Alpha", "Beta"] {
            for i in 1...5 {
                var links = (1...5).filter { $0 != i }.map { "[[\(topic) \($0)]]" }
                if topic == "Alpha", i == 1 { links.append("[[Beta 1]]") }
                let type = i == 3 ? "concept" : "source"
                try env.write("Topics/\(topic) \(i).md", "---\ntype: \(type)\nstatus: [seed]\n---\n\(links.joined(separator: " "))\n")
            }
        }
        let all = ["Alpha", "Beta"].flatMap { t in (1...5).map { "[[\(t) \($0)]]" } }
        try env.write("Index.md", all.joined(separator: "\n"))
    }

    static func makeIndexer() async throws -> (Env, Indexer) {
        let base = try Env(copyFixture: false)
        let vault = base.tmp.sub("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        var config = base.config
        config.vault = vault
        config.graph.excludePatterns = ["Index.md"]
        // The default resolution is meant for thousands of notes; it splits
        // a topic of five.
        config.graph.resolution = 1
        let env = Env(tmp: base.tmp, vault: vault, config: config)
        try writeVault(env)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        return (env, indexer)
    }

    struct Snapshot: Equatable {
        var clusters: [Int64: String]
        var membership: [String: Int64]
        var types: [String: Int]
    }

    static func snapshot(_ indexer: Indexer) async throws -> Snapshot {
        try await indexer.query { db in
            let clusters = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, label FROM graph_clusters").map { ($0[0] as Int64, $0[1] as String) })
            let membership = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT n.path, g.cluster_id FROM graph_nodes g JOIN notes n ON n.id = g.note_id").map { ($0[0] as String, $0[1] as Int64) })
            let types = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT name, node_count FROM graph_types").map { ($0[0] as String, $0[1] as Int) })
            return Snapshot(clusters: clusters, membership: membership, types: types)
        }
    }

    @Test func clustersTopicsAndNamesThemAfterConcepts() async throws {
        let (env, indexer) = try await Self.makeIndexer()
        let summary = try await indexer.refreshGraphForTesting()
        #expect(summary.clusters == 2)
        let snap = try await Self.snapshot(indexer)
        #expect(snap.membership["Index.md"] == nil, "excluded notes are not in the graph")
        #expect(snap.membership.count == 10)
        #expect(snap.membership["Topics/Alpha 2.md"] == snap.membership["Topics/Alpha 5.md"])
        #expect(snap.membership["Topics/Alpha 2.md"] != snap.membership["Topics/Beta 2.md"])
        #expect(Set(snap.clusters.values) == ["Alpha 3", "Beta 3"], "concept notes name their cluster")
        #expect(snap.types == ["concept": 2, "source": 8])
        try await indexer.query { db in
            let status = try String.fetchAll(db, sql: "SELECT DISTINCT status FROM graph_nodes")
            #expect(status == ["seed"], "a list value takes its first item")
            for row in try Row.fetchAll(db, sql: "SELECT x, y FROM graph_nodes") {
                let x: Double = row[0], y: Double = row[1]
                // Inside the unit disk, up to rounding to four decimals.
                #expect(x * x + y * y <= 1.0003, "\(x), \(y)")
            }
            let links = try Row.fetchAll(db, sql: "SELECT weight, skeleton FROM graph_cluster_links")
            #expect(links.count == 1)
            #expect(links.first?["weight"] as Int? == 1)
            #expect(links.first?["skeleton"] as Bool? == true)
            // Overview bubbles do not overlap.
            let c = try Row.fetchAll(db, sql: "SELECT x, y, size FROM graph_clusters")
            let dx = (c[0]["x"] as Double) - (c[1]["x"] as Double), dy = (c[0]["y"] as Double) - (c[1]["y"] as Double)
            let minimum = GraphGeometry.clusterRadius(size: c[0]["size"]) + GraphGeometry.clusterRadius(size: c[1]["size"])
            #expect((dx * dx + dy * dy).squareRoot() >= minimum)
        }
        _ = env
    }

    @Test func unchangedGraphWritesNothingAndSmallEditsKeepTheMap() async throws {
        let (env, indexer) = try await Self.makeIndexer()
        _ = try await indexer.refreshGraphForTesting()
        let before = try await Self.snapshot(indexer)
        let positions = try await indexer.query { db in try Row.fetchAll(db, sql: "SELECT note_id, x, y FROM graph_nodes WHERE cluster_id = (SELECT cluster_id FROM graph_nodes JOIN notes ON notes.id = note_id WHERE path = 'Topics/Beta 1.md')").map { "\($0[0] as Int64):\($0[1] as Double),\($0[2] as Double)" } }

        #expect(try await indexer.refreshGraphForTesting().unchanged)

        // A new note in the Alpha topic: Alpha is laid out again, Beta is not
        // touched, and every cluster keeps its id.
        try env.write("Topics/Alpha 6.md", "[[Alpha 1]] [[Alpha 2]] [[Alpha 3]]")
        _ = try await indexer.reconcile()
        let summary = try await indexer.refreshGraphForTesting()
        #expect(summary.laidOutClusters == 1)
        let after = try await Self.snapshot(indexer)
        #expect(after.clusters.keys.sorted() == before.clusters.keys.sorted())
        #expect(after.membership["Topics/Alpha 6.md"] == before.membership["Topics/Alpha 1.md"])
        let positionsAfter = try await indexer.query { db in try Row.fetchAll(db, sql: "SELECT note_id, x, y FROM graph_nodes WHERE cluster_id = (SELECT cluster_id FROM graph_nodes JOIN notes ON notes.id = note_id WHERE path = 'Topics/Beta 1.md')").map { "\($0[0] as Int64):\($0[1] as Double),\($0[2] as Double)" } }
        #expect(positions == positionsAfter)
    }

    @Test func publishedSnapshotCarriesTheGraph() async throws {
        let (env, indexer) = try await Self.makeIndexer()
        let result = try #require(try await indexer.publish())
        let queue = try DatabaseQueue(path: result.databaseURL.path)
        let (nodes, clusters, state) = try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM graph_nodes"),
             try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'graph_cluster_count'"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM builder_state"))
        }
        #expect(nodes == 10)
        #expect(clusters == "2")
        #expect(state == 0, "graph state stays on the Mac")
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    /// Graph state from before layoutVersion: the next start publishes, so
    /// its layouts are repaired without waiting for an edit in the vault.
    @Test func outdatedLayoutsArePublishedOnStart() async throws {
        let env = try await { () async throws -> Env in
            let (env, indexer) = try await Self.makeIndexer()
            _ = try #require(try await indexer.publish())
            #expect(await indexer.hasUnpublishedChanges == false)
            #expect(try await indexer.needsLayoutRepair() == false)
            // As an earlier version wrote it: no layoutVersion.
            try await indexer.editGraphState { $0["layoutVersion"] = nil }
            #expect(try await indexer.needsLayoutRepair())
            return env
        }()

        let indexer = try Indexer(configuration: env.config)
        #expect(await indexer.hasUnpublishedChanges)
        _ = try #require(try await indexer.publish())
        #expect(try await indexer.needsLayoutRepair() == false)
    }

    /// Clusters from another method (Louvain before) are not followed: the
    /// next start publishes clusters found afresh.
    @Test func clustersOfAnotherMethodAreRecomputedOnStart() async throws {
        let (env, indexer) = try await Self.makeIndexer()
        _ = try #require(try await indexer.publish())
        let before = try await Self.snapshot(indexer)
        try await indexer.editGraphState { $0["method"] = nil }
        #expect(try await indexer.needsLayoutRepair())
        let summary = try await indexer.refreshGraphForTesting()
        #expect(!summary.unchanged)
        #expect(try await Self.snapshot(indexer).membership.count == before.membership.count)
        #expect(try await indexer.needsLayoutRepair() == false)
        #expect(try await indexer.refreshGraphForTesting().unchanged)
        _ = env
    }

    /// Overview order (by size) need not follow id order; the skeleton must
    /// not depend on it.
    @Test func skeletonIgnoresIdOrder() {
        let links: [(a: Int, b: Int, weight: Double)] = [(0, 1, 3), (1, 2, 1)]
        let skeleton = GraphBuilder.skeletonLinks(count: 3, links: links)
        #expect(skeleton == [WeightedGraph.pairKey(0, 1), WeightedGraph.pairKey(1, 2)])
    }

    @Test func largerClusterWithHigherIdKeepsSkeleton() async throws {
        let (env, indexer) = try await Self.makeIndexer()
        // Make Beta the larger cluster (Alpha got the lower id first).
        for i in 6...9 {
            try env.write("Topics/Beta \(i).md", "[[Beta 1]] [[Beta 2]] [[Beta 3]]")
        }
        _ = try await indexer.reconcile()
        _ = try await indexer.refreshGraphForTesting()
        let skeleton = try await indexer.query { db in try Bool.fetchAll(db, sql: "SELECT skeleton FROM graph_cluster_links") }
        #expect(skeleton == [true])
    }

    @Test func patterns() {
        #expect(GraphConfiguration.matches("wiki", "wiki/concepts/A.md"))
        #expect(GraphConfiguration.matches("wiki/*", "wiki/concepts/A.md"))
        #expect(GraphConfiguration.matches("Wiki/Index.md", "wiki/index.md"))
        #expect(!GraphConfiguration.matches("wiki", "wikipedia/A.md"))
        var config = GraphConfiguration()
        config.includePatterns = ["wiki"]
        config.excludePatterns = ["wiki/meta"]
        #expect(config.contains("wiki/concepts/A.md"))
        #expect(!config.contains("wiki/meta/A.md"))
        #expect(!config.contains("notes/A.md"))
    }
}

extension Indexer {
    func refreshGraphForTesting() throws -> GraphBuilder.Summary {
        try GraphBuilder.refresh(builder: builder, configuration: configuration.graph)
    }
}

extension Indexer {
    func needsLayoutRepair() throws -> Bool {
        try GraphBuilder.needsLayoutRepair(builder: builder, configuration: configuration.graph)
    }

    func editGraphState(_ edit: (inout [String: Any]) -> Void) throws {
        let json = try builder.state(GraphBuilder.stateKey) ?? "{}"
        var state = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        edit(&state)
        try builder.setState(GraphBuilder.stateKey, String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
    }
}
