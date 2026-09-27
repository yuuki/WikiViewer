//
//  GraphRepository.swift
//  WikiViewerKit
//
//  Bounded queries over the link graph the host has analysed (graph_*
//  tables) and over links for a note's neighbourhood. The phone never loads
//  the whole graph: the overview reads at most GraphGeometry.overviewClusters
//  clusters, a cluster view at most `clusterNodeLimit` of its notes (the most
//  linked first), and a local graph a few dozen notes.
//

import Foundation
import GRDB
import WikiShared

public struct GraphCluster: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// The cluster's most linked note of the preferred type.
    public var label: String
    public var size: Int
    /// Centre on the overview, in GraphGeometry.clusterRadius units.
    public var x: Double
    public var y: Double

    public var radius: Double { GraphGeometry.clusterRadius(size: size) }
}

public struct GraphClusterLink: Hashable, Sendable {
    public var a: Int64
    public var b: Int64
    public var weight: Int
    /// Drawn on the overview by default (spanning tree + strongest links).
    public var skeleton: Bool
}

public struct GraphOverview: Sendable {
    public var clusters: [GraphCluster]
    public var links: [GraphClusterLink]
    /// Clusters and notes in the whole graph (the overview shows the largest).
    public var clusterCount: Int
    public var nodeCount: Int
}

public struct GraphNode: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var path: String
    /// nil if the note is not in the graph (outside its scope, or in no
    /// cluster); it can still appear in a local graph.
    public var cluster: Int64?
    /// Position in the cluster's layout (unit disk).
    public var x: Double
    public var y: Double
    /// Incoming links from other notes in the graph.
    public var weight: Int
    public var degree: Int
    public var type: String?
    public var status: String?
}

/// Undirected link between two notes; weight counts links both ways.
public struct GraphEdge: Hashable, Sendable {
    public var a: Int64
    public var b: Int64
    public var weight: Int
}

public struct ClusterGraph: Sendable {
    public var cluster: GraphCluster
    /// The cluster's most linked notes, at most `GraphRepository.clusterNodeLimit`.
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    /// The strongest links to other clusters, for leaving this one.
    public var neighbours: [(cluster: GraphCluster, weight: Int)]

    public var isTruncated: Bool { nodes.count < cluster.size }
}

public struct GraphNeighbour: Identifiable, Hashable, Sendable {
    public var node: GraphNode
    /// Links between the two notes, both directions.
    public var weight: Int
    public var id: Int64 { node.id }
}

/// A note, its most relevant neighbours and theirs, and the links it makes
/// to notes that do not exist.
public struct LocalGraph: Sendable {
    public struct Member: Identifiable, Hashable, Sendable {
        public var node: GraphNode
        /// 0 for the centre, 1 for direct neighbours, 2 for theirs.
        public var depth: Int
        /// Relevance to the centre (higher is closer).
        public var score: Double
        /// For depth 2: the direct neighbour it is reached through.
        public var parent: Int64?
        public var id: Int64 { node.id }
    }

    public var center: GraphNode
    /// Centre first, then depth 1 by score, then depth 2 by score.
    public var members: [Member]
    public var edges: [GraphEdge]
    /// Targets of the centre's unresolved links.
    public var missing: [String]
}

public struct GraphType: Identifiable, Hashable, Sendable {
    public var name: String
    public var count: Int
    public var id: String { name }
}

public struct GraphRepository: Sendable {
    public let database: ViewerDatabase

    /// Notes shown for one cluster: enough to see its structure, few enough
    /// to draw every frame.
    public static let clusterNodeLimit = 400
    /// Direct and second-degree neighbours in a local graph.
    public static let localFirstDegree = 20
    public static let localSecondDegree = 16
    static let localExpanded = 10
    static let localMissing = 12

    public init(database: ViewerDatabase) {
        self.database = database
    }

    // MARK: Overview

    public func overview(limit: Int = GraphGeometry.overviewClusters) async throws -> GraphOverview {
        try await database.reader.read { db in
            let clusters = try Row.fetchAll(db, sql: "SELECT * FROM graph_clusters ORDER BY size DESC, id DESC LIMIT ?",
                                            arguments: [min(max(limit, 1), maxPage)]).map(Self.cluster)
            let ids = clusters.map(\.id)
            var links: [GraphClusterLink] = []
            if !ids.isEmpty {
                let list = Self.placeholders(ids.count)
                links = try Row.fetchAll(db, sql: """
                    SELECT * FROM graph_cluster_links WHERE cluster_a IN (\(list)) AND cluster_b IN (\(list))
                    """, arguments: StatementArguments(ids + ids)).map(Self.link)
            }
            let meta = try Dictionary(Row.fetchAll(db, sql: "SELECT key, value FROM meta WHERE key IN (?, ?)",
                                                   arguments: [ViewerSchema.MetaKey.graphClusterCount, ViewerSchema.MetaKey.graphNodeCount])
                                          .map { ($0[0] as String, $0[1] as String) }, uniquingKeysWith: { a, _ in a })
            return GraphOverview(
                clusters: clusters, links: links,
                clusterCount: Int(meta[ViewerSchema.MetaKey.graphClusterCount] ?? "") ?? clusters.count,
                nodeCount: Int(meta[ViewerSchema.MetaKey.graphNodeCount] ?? "") ?? clusters.reduce(0) { $0 + $1.size })
        }
    }

    /// All clusters, largest first, keyset-paginated (graph_clusters_size).
    public func clusters(after cursor: GraphCluster? = nil, limit: Int = 100) async throws -> Page<GraphCluster> {
        let limit = clampLimit(limit)
        return try await database.reader.read { db in
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM graph_clusters WHERE size < ? OR (size = ? AND id < ?)
                    ORDER BY size DESC, id DESC LIMIT ?
                    """, arguments: [cursor.size, cursor.size, cursor.id, limit + 1])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM graph_clusters ORDER BY size DESC, id DESC LIMIT ?", arguments: [limit + 1])
            }
            return Page(items: rows.prefix(limit).map(Self.cluster), hasMore: rows.count > limit)
        }
    }

    public func cluster(id: Int64) async throws -> GraphCluster? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM graph_clusters WHERE id = ?", arguments: [id]).map(Self.cluster)
        }
    }

    /// A cluster's most linked notes (graph_nodes_cluster).
    public func members(of cluster: Int64, limit: Int = 5) async throws -> [GraphNode] {
        try await database.reader.read { db in try Self.members(db, cluster: cluster, limit: clampLimit(limit)) }
    }

    public func types() async throws -> [GraphType] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT name, node_count FROM graph_types ORDER BY node_count DESC, name LIMIT 100")
                .map { GraphType(name: $0[0], count: $0[1]) }
        }
    }

    // MARK: One cluster

    public func clusterGraph(id: Int64, limit: Int = clusterNodeLimit) async throws -> ClusterGraph? {
        try await database.reader.read { db in
            guard let cluster = try Row.fetchOne(db, sql: "SELECT * FROM graph_clusters WHERE id = ?", arguments: [id]).map(Self.cluster) else { return nil }
            let nodes = try Self.members(db, cluster: id, limit: min(max(limit, 1), Self.clusterNodeLimit))
            let edges = try Self.edges(db, among: nodes.map(\.id))
            let neighbourLinks = try Row.fetchAll(db, sql: """
                SELECT cluster_b AS other, weight FROM graph_cluster_links WHERE cluster_a = ?
                UNION ALL
                SELECT cluster_a AS other, weight FROM graph_cluster_links WHERE cluster_b = ?
                ORDER BY weight DESC LIMIT 8
                """, arguments: [id, id])
            var neighbours: [(GraphCluster, Int)] = []
            for row in neighbourLinks {
                if let other = try Row.fetchOne(db, sql: "SELECT * FROM graph_clusters WHERE id = ?", arguments: [row["other"] as Int64]).map(Self.cluster) {
                    neighbours.append((other, row["weight"]))
                }
            }
            return ClusterGraph(cluster: cluster, nodes: nodes, edges: edges, neighbours: neighbours)
        }
    }

    // MARK: One note

    public func node(id: Int64) async throws -> GraphNode? {
        try await database.reader.read { db in try Self.nodes(db, ids: [id])[id] }
    }

    public func node(path: String) async throws -> GraphNode? {
        try await database.reader.read { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [path]) else { return nil }
            return try Self.nodes(db, ids: [id])[id]
        }
    }

    /// Notes linked to or from a note, most links first. For a note in the
    /// graph, only notes in the graph: the ones left out are typically
    /// indexes and logs that link to everything.
    public func neighbours(of id: Int64, limit: Int = 30) async throws -> [GraphNeighbour] {
        try await database.reader.read { db in
            let limit = clampLimit(limit)
            let graphOnly = try Self.nodes(db, ids: [id])[id]?.cluster != nil
            let weights = try Self.neighbourWeights(db, of: id, limit: graphOnly ? maxPage : limit)
            let nodes = try Self.nodes(db, ids: weights.map(\.0))
            let result = weights.compactMap { other, weight in nodes[other].map { GraphNeighbour(node: $0, weight: weight) } }
            return Array(result.filter { !graphOnly || $0.node.cluster != nil }.prefix(limit))
        }
    }

    /// The neighbourhood of a note, ranked by relevance rather than cut at a
    /// fixed depth: direct neighbours score by their links to the centre,
    /// discounted by how connected they are (a hub linked from everywhere
    /// says little); second-degree notes score by the relevance of the
    /// neighbours they are reached through and by their own backlinks. Bounded: about a dozen small
    /// queries and a few dozen notes whatever the size of the vault.
    public func localGraph(of id: Int64) async throws -> LocalGraph? {
        try await database.reader.read { db in
            guard let center = try Self.nodes(db, ids: [id])[id] else { return nil }
            // As for neighbours: a note in the graph gets a neighbourhood in
            // the graph, without the indexes left out of it.
            let graphOnly = center.cluster != nil
            var first = try Self.neighbourWeights(db, of: id, limit: 200)
            var info = try Self.nodes(db, ids: first.map(\.0))
            if graphOnly { first = first.filter { info[$0.0]?.cluster != nil } }
            func discount(_ node: GraphNode?) -> Double { log2(2 + Double(node?.degree ?? 1)) }

            var ring1 = first.map { other, weight in (id: other, score: Double(weight) / discount(info[other])) }
            ring1.sort { ($0.score, $1.id) > ($1.score, $0.id) }
            ring1 = Array(ring1.prefix(Self.localFirstDegree))
            let direct = Set(first.map(\.0))

            var score2: [Int64: Double] = [:]
            var parent: [Int64: (Int64, Double)] = [:]
            for p in ring1.prefix(Self.localExpanded) {
                for (other, weight) in try Self.neighbourWeights(db, of: p.id, limit: 60) where other != id && !direct.contains(other) {
                    let contribution = p.score * Double(weight)
                    score2[other, default: 0] += contribution
                    if contribution > parent[other]?.1 ?? 0 { parent[other] = (p.id, contribution) }
                }
            }
            let secondIDs = Array(score2.keys)
            for (k, v) in try Self.nodes(db, ids: secondIDs) { info[k] = v }
            if graphOnly { score2 = score2.filter { info[$0.key]?.cluster != nil } }
            // Second-degree notes also need standing of their own: otherwise
            // stubs linked from a single neighbour fill the outer ring.
            var ring2 = score2.map { (id: $0.key, score: $0.value * log2(2 + Double(info[$0.key]?.weight ?? 0)) / discount(info[$0.key])) }
            ring2.sort { ($0.score, $1.id) > ($1.score, $0.id) }
            ring2 = Array(ring2.prefix(Self.localSecondDegree))

            var members = [LocalGraph.Member(node: center, depth: 0, score: .infinity, parent: nil)]
            for r in ring1 { if let node = info[r.id] { members.append(.init(node: node, depth: 1, score: r.score, parent: nil)) } }
            for r in ring2 { if let node = info[r.id] { members.append(.init(node: node, depth: 2, score: r.score, parent: parent[r.id]?.0)) } }
            let edges = try Self.edges(db, among: members.map(\.node.id))

            let missing = try String.fetchAll(db, sql: """
                SELECT DISTINCT target_path FROM links
                WHERE source_note_id = ? AND target_note_id IS NULL AND target_asset_id IS NULL AND is_embed = 0
                LIMIT ?
                """, arguments: [id, Self.localMissing * 2])
                .filter { target in
                    // Links to missing files (images, PDFs…) are not missing notes.
                    let ext = (target as NSString).pathExtension.lowercased()
                    return ext.isEmpty || ext == "md"
                }
            return LocalGraph(center: center, members: members, edges: edges, missing: Array(missing.prefix(Self.localMissing)))
        }
    }

    // MARK: Helpers

    static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    static func cluster(_ row: Row) -> GraphCluster {
        GraphCluster(id: row["id"], label: row["label"], size: row["size"], x: row["x"], y: row["y"])
    }

    static func link(_ row: Row) -> GraphClusterLink {
        GraphClusterLink(a: row["cluster_a"], b: row["cluster_b"], weight: row["weight"], skeleton: row["skeleton"])
    }

    static func node(_ row: Row) -> GraphNode {
        GraphNode(id: row["id"], title: row["title"], path: row["path"], cluster: row["cluster_id"],
                  x: row["x"] ?? 0, y: row["y"] ?? 0, weight: row["weight"] ?? 0, degree: row["degree"] ?? 0,
                  type: row["type"], status: row["status"])
    }

    static let nodeColumns = "n.id, n.title, n.path, g.cluster_id, g.x, g.y, g.weight, g.degree, g.type, g.status"

    static func members(_ db: Database, cluster: Int64, limit: Int) throws -> [GraphNode] {
        try Row.fetchAll(db, sql: """
            SELECT \(nodeColumns) FROM graph_nodes g JOIN notes n ON n.id = g.note_id
            WHERE g.cluster_id = ? ORDER BY g.weight DESC, g.note_id DESC LIMIT ?
            """, arguments: [cluster, limit]).map(node)
    }

    /// Notes by id (primary keys), with their graph data if they have any.
    static func nodes(_ db: Database, ids: [Int64]) throws -> [Int64: GraphNode] {
        var result: [Int64: GraphNode] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[start..<min(start + 500, ids.count)])
            for row in try Row.fetchAll(db, sql: """
                SELECT \(nodeColumns) FROM notes n LEFT JOIN graph_nodes g ON g.note_id = n.id
                WHERE n.id IN (\(placeholders(slice.count)))
                """, arguments: StatementArguments(slice)) {
                let n = node(row)
                result[n.id] = n
            }
        }
        return result
    }

    /// Links between the given notes, merged into undirected edges. Reads
    /// each note's own link rows (primary key ranges).
    static func edges(_ db: Database, among ids: [Int64]) throws -> [GraphEdge] {
        guard ids.count > 1 else { return [] }
        let list = placeholders(ids.count)
        var weights: [Pair: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT source_note_id, target_note_id, count(*) FROM links
            WHERE source_note_id IN (\(list)) AND target_note_id IN (\(list)) AND target_note_id != source_note_id
            GROUP BY source_note_id, target_note_id
            """, arguments: StatementArguments(ids + ids)) {
            let s: Int64 = row[0], t: Int64 = row[1]
            weights[Pair(min(s, t), max(s, t)), default: 0] += row[2] as Int
        }
        return weights.map { GraphEdge(a: $0.key.a, b: $0.key.b, weight: $0.value) }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    struct Pair: Hashable {
        var a: Int64
        var b: Int64
        init(_ a: Int64, _ b: Int64) {
            self.a = a
            self.b = b
        }
    }

    /// (other note, links both ways), most links first. Incoming links are
    /// read through links_target_note and capped, so a hub with tens of
    /// thousands of backlinks costs a bounded scan.
    static func neighbourWeights(_ db: Database, of id: Int64, limit: Int) throws -> [(Int64, Int)] {
        try Row.fetchAll(db, sql: """
            SELECT other, sum(c) AS w FROM (
              SELECT target_note_id AS other, count(*) AS c FROM links
              WHERE source_note_id = ? AND target_note_id IS NOT NULL AND target_note_id != ?
              GROUP BY target_note_id
              UNION ALL
              SELECT source_note_id AS other, count(*) AS c FROM (
                SELECT source_note_id FROM links WHERE target_note_id = ? AND source_note_id != ? LIMIT 2000
              ) GROUP BY source_note_id
            ) GROUP BY other ORDER BY w DESC, other LIMIT ?
            """, arguments: [id, id, id, id, limit]).map { ($0[0], $0[1]) }
    }
}
