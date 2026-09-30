//
//  GraphBuilder.swift
//  IndexerCore
//
//  Analyses the link graph before each publication and stores the result in
//  the graph_* tables (see ViewerSchema), so the phone can draw the vault's
//  structure without ever holding the whole graph:
//
//    notes + resolved links ─▶ undirected weighted graph (notes in scope)
//      ─▶ Louvain communities, started from the previous clusters
//      ─▶ stable cluster ids (matched to the previous ones by overlap)
//      ─▶ ForceAtlas2 layout of each changed cluster, started from its
//         previous layout; unchanged clusters keep theirs exactly
//      ─▶ overview: the largest clusters as non-overlapping bubbles, plus a
//         skeleton of their strongest links
//      ─▶ only the rows that differ are written
//
//  Stability is the point of most of this: a one-note edit should neither
//  reshuffle the map the reader has learned nor rewrite thousands of rows
//  (which would make every delta pack large).
//

import CryptoKit
import Foundation
import GRDB
import WikiShared

/// Which notes the graph covers and how clusters are named.
public struct GraphConfiguration: Sendable, Equatable {
    /// If any are given, only notes whose path matches one are in the graph.
    /// A pattern matches a note path with fnmatch(3) (`*` also crosses
    /// "/"), or a folder and everything in it. Case-insensitive.
    public var includePatterns: [String] = []
    /// Notes left out of the graph, typically indexes and logs that link to
    /// everything and would pull every cluster together.
    public var excludePatterns: [String] = []
    /// A cluster is named after its most linked note, preferring these
    /// frontmatter `type` values in this order.
    public var labelTypes: [String] = ["concept", "question", "entity", "source"]
    /// Turns graph analysis off (the graph tables stay empty).
    public var enabled = true

    public init() {}

    func contains(_ path: String) -> Bool {
        if !includePatterns.isEmpty, !includePatterns.contains(where: { Self.matches($0, path) }) { return false }
        return !excludePatterns.contains { Self.matches($0, path) }
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !pattern.isEmpty else { return false }
        if fnmatch(pattern, path, FNM_CASEFOLD) == 0 { return true }
        return path.lowercased().hasPrefix(pattern.lowercased() + "/")
    }

    var fingerprint: String {
        "v1|\(enabled)|\(includePatterns.joined(separator: "\u{1}"))|\(excludePatterns.joined(separator: "\u{1}"))|\(labelTypes.joined(separator: ","))"
    }
}

public enum GraphBuilder {
    public struct Summary: Sendable, CustomStringConvertible {
        public var unchanged = false
        public var nodes = 0
        public var clusters = 0
        public var laidOutClusters = 0
        public var rowsWritten = 0
        public var seconds = 0.0

        public var description: String {
            if unchanged { return "graph unchanged" }
            return "graph: \(nodes) notes in \(clusters) clusters, \(laidOutClusters) laid out, \(rowsWritten) rows written in \(String(format: "%.3f", seconds))s"
        }
    }

    static let stateKey = "graph_state"

    /// True if the stored graph was laid out by an earlier version whose
    /// layouts need repairing (State.layoutVersion). The indexer then
    /// publishes on start, since refresh only runs with a publication.
    public static func needsLayoutRepair(builder: BuilderDatabase, configuration: GraphConfiguration) throws -> Bool {
        guard configuration.enabled, let json = try builder.state(stateKey),
              let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else { return false }
        return state.layoutVersion != State.layoutVersion
    }

    /// Recomputes the graph tables if the notes or links in scope changed.
    @discardableResult
    public static func refresh(builder: BuilderDatabase, configuration: GraphConfiguration) throws -> Summary {
        let start = Clock.now()
        var state = (try builder.state(stateKey)).flatMap { try? JSONDecoder().decode(State.self, from: Data($0.utf8)) } ?? State()
        let input = configuration.enabled ? try builder.writer.read { try Input.load($0, configuration: configuration) } : Input()
        let fingerprint = input.fingerprint(configuration)
        if fingerprint == state.fingerprint, state.layoutVersion == State.layoutVersion {
            return Summary(unchanged: true)
        }
        let previous = try builder.writer.read { try Rows.load($0) }
        let rows = compute(input: input, previous: previous, state: &state, configuration: configuration)
        state.fingerprint = fingerprint
        state.layoutVersion = State.layoutVersion
        let stateJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let written = try builder.writer.write { db in
            let n = try rows.write(db, replacing: previous)
            try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES (?, ?)", arguments: [stateKey, stateJSON])
            return n
        }
        var summary = Summary()
        summary.nodes = rows.nodes.count
        summary.clusters = rows.clusters.count
        summary.laidOutClusters = rows.laidOut
        summary.rowsWritten = written
        summary.seconds = Clock.seconds(since: start)
        return summary
    }

    // MARK: State kept between publications (builder only)

    struct State: Codable {
        /// Raised when layouts from earlier versions need repairing: the
        /// next refresh then runs even if the graph did not change (only
        /// the clusters that need it are laid out again). 1: layouts that
        /// diverged before steps were bounded.
        static let layoutVersion = 1

        var fingerprint = ""
        var layoutVersion: Int?
        /// Cluster ids are never reused, so a removed cluster's colour does
        /// not jump to an unrelated one.
        var nextClusterID: Int64 = 1
        /// Per cluster: digest of its members and inner links when it was
        /// last laid out, and the layout's scale before normalization.
        var clusters: [String: ClusterLayout] = [:]
        var overview: Overview?

        struct ClusterLayout: Codable {
            var digest: String
            var scale: Double
        }

        struct Overview: Codable {
            var ids: [Int64]
            var sizes: [Int]
            var scale: Double
        }
    }

    // MARK: Input

    struct Node {
        var id: Int64
        var title: String
        var type: String?
        var status: String?
    }

    struct Input {
        /// Notes in scope that have at least one link to another, by id.
        var nodes: [Node] = []
        /// Undirected links between node indices (a < b), weight = number
        /// of links in both directions. Sorted.
        var edges: [(a: Int, b: Int, weight: Double)] = []
        /// Incoming links per node from other nodes.
        var inbound: [Int] = []

        static func load(_ db: Database, configuration: GraphConfiguration) throws -> Input {
            var notes: [Int64: Node] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT n.id, n.path, n.title,
                  CAST((SELECT json_extract(j.value, '$[1]') FROM json_each(n.frontmatter) AS j
                        WHERE lower(json_extract(j.value, '$[0]')) = 'type' LIMIT 1) AS TEXT) AS type,
                  CAST((SELECT json_extract(j.value, '$[1]') FROM json_each(n.frontmatter) AS j
                        WHERE lower(json_extract(j.value, '$[0]')) = 'status' LIMIT 1) AS TEXT) AS status
                FROM notes AS n
                """)
            while let row = try rows.next() {
                let path: String = row["path"]
                guard configuration.contains(path) else { continue }
                notes[row["id"]] = Node(id: row["id"], title: row["title"], type: property(row["type"]), status: property(row["status"]))
            }

            var directed: [(Int64, Int64, Int)] = []
            let links = try Row.fetchCursor(db, sql: """
                SELECT source_note_id, target_note_id, count(*) FROM links
                WHERE target_note_id IS NOT NULL AND target_note_id != source_note_id
                GROUP BY source_note_id, target_note_id
                """)
            var linked = Set<Int64>()
            while let row = try links.next() {
                let source: Int64 = row[0], target: Int64 = row[1]
                guard notes[source] != nil, notes[target] != nil else { continue }
                directed.append((source, target, row[2]))
                linked.insert(source)
                linked.insert(target)
            }

            var input = Input()
            input.nodes = linked.sorted().map { notes[$0]! }
            var index: [Int64: Int] = [:]
            for (i, node) in input.nodes.enumerated() { index[node.id] = i }
            input.inbound = [Int](repeating: 0, count: input.nodes.count)
            var pairs: [UInt64: Double] = [:]
            for (source, target, count) in directed {
                let a = index[source]!, b = index[target]!
                input.inbound[b] += count
                pairs[Louvain.pairKey(min(a, b), max(a, b)), default: 0] += Double(count)
            }
            input.edges = pairs.map { (Int($0.key >> 32), Int($0.key & 0xFFFF_FFFF), $0.value) }
            input.edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
            return input
        }

        /// A frontmatter scalar, or the first string of a list, lowercased.
        static func property(_ raw: String?) -> String? {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            if value.hasPrefix("["), let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [Any] {
                guard let first = list.first as? String else { return nil }
                value = first.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { return nil }
            return String(value.lowercased().prefix(40))
        }

        func fingerprint(_ configuration: GraphConfiguration) -> String {
            var hasher = SHA256()
            func add(_ s: String) { hasher.update(data: Data(s.utf8)); hasher.update(data: Data([0])) }
            add(configuration.fingerprint)
            for node in nodes {
                add("\(node.id)|\(node.title)|\(node.type ?? "")|\(node.status ?? "")")
            }
            for e in edges { add("\(e.a),\(e.b),\(e.weight)") }
            for w in inbound { add(String(w)) }
            return Digest.hex(hasher.finalize())
        }
    }

    // MARK: Rows

    struct NodeRow: Equatable {
        var cluster: Int64
        var x: Double
        var y: Double
        var weight: Int
        var degree: Int
        var type: String?
        var status: String?
    }

    struct ClusterRow: Equatable {
        var label: String
        var size: Int
        var x: Double
        var y: Double
    }

    struct LinkRow: Equatable {
        var weight: Int
        var skeleton: Bool
    }

    struct PairKey: Hashable, Comparable {
        var a: Int64
        var b: Int64
        static func < (l: PairKey, r: PairKey) -> Bool { (l.a, l.b) < (r.a, r.b) }
    }

    struct Rows {
        var nodes: [Int64: NodeRow] = [:]
        var clusters: [Int64: ClusterRow] = [:]
        var links: [PairKey: LinkRow] = [:]
        var types: [String: Int] = [:]
        var laidOut = 0

        static func load(_ db: Database) throws -> Rows {
            var rows = Rows()
            for row in try Row.fetchAll(db, sql: "SELECT * FROM graph_nodes") {
                rows.nodes[row["note_id"]] = NodeRow(cluster: row["cluster_id"], x: row["x"], y: row["y"], weight: row["weight"], degree: row["degree"], type: row["type"], status: row["status"])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM graph_clusters") {
                rows.clusters[row["id"]] = ClusterRow(label: row["label"], size: row["size"], x: row["x"], y: row["y"])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM graph_cluster_links") {
                rows.links[PairKey(a: row["cluster_a"], b: row["cluster_b"])] = LinkRow(weight: row["weight"], skeleton: row["skeleton"])
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM graph_types") {
                rows.types[row["name"]] = row["node_count"]
            }
            return rows
        }

        /// Writes only rows that differ from `old`. Returns rows touched.
        func write(_ db: Database, replacing old: Rows) throws -> Int {
            let before = db.totalChangesCount
            for id in old.nodes.keys where nodes[id] == nil {
                try db.execute(sql: "DELETE FROM graph_nodes WHERE note_id = ?", arguments: [id])
            }
            for (id, row) in nodes.sorted(by: { $0.key < $1.key }) where old.nodes[id] != row {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO graph_nodes(note_id, cluster_id, x, y, weight, degree, type, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, row.cluster, row.x, row.y, row.weight, row.degree, row.type, row.status])
            }
            for id in old.clusters.keys where clusters[id] == nil {
                try db.execute(sql: "DELETE FROM graph_clusters WHERE id = ?", arguments: [id])
            }
            for (id, row) in clusters.sorted(by: { $0.key < $1.key }) where old.clusters[id] != row {
                try db.execute(sql: "INSERT OR REPLACE INTO graph_clusters(id, label, size, x, y) VALUES (?, ?, ?, ?, ?)",
                               arguments: [id, row.label, row.size, row.x, row.y])
            }
            for key in old.links.keys where links[key] == nil {
                try db.execute(sql: "DELETE FROM graph_cluster_links WHERE cluster_a = ? AND cluster_b = ?", arguments: [key.a, key.b])
            }
            for (key, row) in links.sorted(by: { $0.key < $1.key }) where old.links[key] != row {
                try db.execute(sql: "INSERT OR REPLACE INTO graph_cluster_links(cluster_a, cluster_b, weight, skeleton) VALUES (?, ?, ?, ?)",
                               arguments: [key.a, key.b, row.weight, row.skeleton])
            }
            for name in old.types.keys where types[name] == nil {
                try db.execute(sql: "DELETE FROM graph_types WHERE name = ?", arguments: [name])
            }
            for (name, count) in types.sorted(by: { $0.key < $1.key }) where old.types[name] != count {
                try db.execute(sql: "INSERT OR REPLACE INTO graph_types(name, node_count) VALUES (?, ?)", arguments: [name, count])
            }
            return db.totalChangesCount - before
        }
    }

    // MARK: Computation

    static func compute(input: Input, previous: Rows, state: inout State, configuration: GraphConfiguration) -> Rows {
        var rows = Rows()
        let n = input.nodes.count
        guard n > 0 else {
            state.clusters = [:]
            state.overview = nil
            return rows
        }
        let graph = WeightedGraph(nodeCount: n, edges: input.edges)

        // 1. Communities, starting from the previous clusters. Notes that
        //    were not clustered start alone (negative ids never collide).
        let initial = input.nodes.enumerated().map { i, node in previous.nodes[node.id].map { Int($0.cluster) } ?? -(i + 1) }
        let community = Louvain.communities(graph, initial: initial)
        var groups: [[Int]] = Array(repeating: [], count: (community.max() ?? -1) + 1)
        for (i, c) in community.enumerated() { groups[c].append(i) }
        groups = groups.filter { $0.count >= GraphGeometry.minimumClusterSize }

        // 2. Stable ids: a group keeps the id of the previous cluster it
        //    shares most notes with, if that is a majority of either.
        let clusterIDs = matchClusterIDs(groups: groups, nodes: input.nodes, previous: previous, state: &state)
        var clusterOf = [Int64?](repeating: nil, count: n)
        for (g, members) in groups.enumerated() {
            for i in members { clusterOf[i] = clusterIDs[g] }
        }

        // 3. Layout within each cluster.
        var degree = [Int](repeating: 0, count: n)
        for i in 0..<n { degree[i] = graph.offsets[i + 1] - graph.offsets[i] }
        var liveLayouts: [String: State.ClusterLayout] = [:]
        for (g, members) in groups.enumerated() {
            let id = clusterIDs[g]
            let key = String(id)
            let (positions, layout, laidOut) = layoutCluster(
                id: id, members: members, graph: graph, clusterOf: clusterOf, nodes: input.nodes,
                previous: previous, previousLayout: state.clusters[key])
            liveLayouts[key] = layout
            if laidOut { rows.laidOut += 1 }
            for (k, i) in members.enumerated() {
                let node = input.nodes[i]
                rows.nodes[node.id] = NodeRow(cluster: id, x: positions[k].x, y: positions[k].y,
                                              weight: input.inbound[i], degree: degree[i], type: node.type, status: node.status)
                if let type = node.type { rows.types[type, default: 0] += 1 }
            }
            rows.clusters[id] = ClusterRow(label: label(members: members, input: input, configuration: configuration), size: members.count, x: 0, y: 0)
        }
        state.clusters = liveLayouts

        // 4. Links between clusters.
        var between: [PairKey: Double] = [:]
        for e in input.edges {
            guard let ca = clusterOf[e.a], let cb = clusterOf[e.b], ca != cb else { continue }
            between[PairKey(a: min(ca, cb), b: max(ca, cb)), default: 0] += e.weight
        }

        // 5. Overview of the largest clusters.
        let top = rows.clusters.sorted { ($0.value.size, $1.key) > ($1.value.size, $0.key) }
            .prefix(GraphGeometry.overviewClusters).map(\.key)
        let topIndex = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1, $0) })
        let topLinks: [(a: Int, b: Int, weight: Double)] = between.compactMap { key, w in
            guard let a = topIndex[key.a], let b = topIndex[key.b] else { return nil }
            return (min(a, b), max(a, b), w)
        }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        let positions = overviewLayout(ids: top, sizes: top.map { rows.clusters[$0]!.size }, links: topLinks, previous: previous, state: &state)
        for (i, id) in top.enumerated() {
            rows.clusters[id]!.x = positions[i].x
            rows.clusters[id]!.y = positions[i].y
        }
        let skeleton = skeletonLinks(count: top.count, links: topLinks)
        for (key, w) in between {
            var drawn = false
            if let a = topIndex[key.a], let b = topIndex[key.b] {
                drawn = skeleton.contains(Louvain.pairKey(min(a, b), max(a, b)))
            }
            rows.links[key] = LinkRow(weight: Int(w), skeleton: drawn)
        }
        return rows
    }

    static func matchClusterIDs(groups: [[Int]], nodes: [Node], previous: Rows, state: inout State) -> [Int64] {
        var previousSize: [Int64: Int] = [:]
        for row in previous.nodes.values { previousSize[row.cluster, default: 0] += 1 }
        state.nextClusterID = max(state.nextClusterID, (previousSize.keys.max() ?? 0) + 1)
        var candidates: [(overlap: Int, group: Int, id: Int64)] = []
        for (g, members) in groups.enumerated() {
            var overlap: [Int64: Int] = [:]
            for i in members {
                if let c = previous.nodes[nodes[i].id]?.cluster { overlap[c, default: 0] += 1 }
            }
            for (id, count) in overlap where count * 2 > members.count || count * 2 > previousSize[id, default: 0] {
                candidates.append((count, g, id))
            }
        }
        candidates.sort { ($0.overlap, $1.group, $1.id) > ($1.overlap, $0.group, $0.id) }
        var ids = [Int64?](repeating: nil, count: groups.count)
        var taken = Set<Int64>()
        for c in candidates where ids[c.group] == nil && !taken.contains(c.id) {
            ids[c.group] = c.id
            taken.insert(c.id)
        }
        return ids.map { id in
            if let id { return id }
            defer { state.nextClusterID += 1 }
            return state.nextClusterID
        }
    }

    /// Positions of a cluster's members in the unit disk, in `members` order.
    static func layoutCluster(id: Int64, members: [Int], graph: WeightedGraph, clusterOf: [Int64?], nodes: [Node],
                              previous: Rows, previousLayout: State.ClusterLayout?) -> ([SIMD2<Double>], State.ClusterLayout, Bool) {
        var local: [Int: Int] = [:]
        for (k, i) in members.enumerated() { local[i] = k }
        var edges: [ForceAtlas2.Edge] = []
        var hasher = SHA256()
        for i in members { hasher.update(data: Data("\(nodes[i].id);".utf8)) }
        for (k, i) in members.enumerated() {
            for e in graph.offsets[i]..<graph.offsets[i + 1] {
                let j = Int(graph.neighbors[e])
                guard i < j, let kj = local[j] else { continue }
                edges.append((k, kj, graph.weights[e]))
                hasher.update(data: Data("\(nodes[i].id)-\(nodes[j].id):\(graph.weights[e]);".utf8))
            }
        }
        let digest = Digest.hex(hasher.finalize())

        let m = members.count
        let spread = 10 * Double(m).squareRoot()
        var old = members.map { i -> SIMD2<Double>? in
            guard let row = previous.nodes[nodes[i].id], row.cluster == id else { return nil }
            return SIMD2(row.x, row.y)
        }
        // A layout spans about `spread`. One far larger diverged (before
        // steps were bounded) and left most notes on a single point after
        // normalization: lay the cluster out afresh.
        var previousLayout = previousLayout
        if let layout = previousLayout, !(spread / 10...spread * 10).contains(layout.scale) {
            previousLayout = nil
            old = old.map { _ in nil }
        }
        if let previousLayout, previousLayout.digest == digest, old.allSatisfy({ $0 != nil }) {
            return (old.map { $0! }, previousLayout, false)
        }

        // Start from the previous layout (at its original scale) where
        // there is one; place newcomers next to their placed neighbours.
        func direction(_ k: Int) -> SIMD2<Double> {
            let angle = 2 * Double.pi * SplitMix64.unit(UInt64(bitPattern: nodes[members[k]].id))
            return SIMD2(cos(angle), sin(angle))
        }
        let scale = previousLayout?.scale ?? spread
        var positions = [SIMD2<Double>](repeating: .zero, count: m)
        var placed = [Bool](repeating: false, count: m)
        var taken = Set<SIMD2<Double>>()
        for k in 0..<m {
            if let p = old[k] {
                positions[k] = p * scale
                // Notes on the same point repel each other with no force
                // at all, so they would never come apart.
                if !taken.insert(positions[k]).inserted { positions[k] += direction(k) * (scale * 0.01) }
                placed[k] = true
            }
        }
        let warm = placed.filter { $0 }.count * 2 >= m
        var neighbours = [[Int]](repeating: [], count: m)
        for e in edges {
            neighbours[e.a].append(e.b)
            neighbours[e.b].append(e.a)
        }
        for k in 0..<m where !placed[k] {
            let seed = UInt64(bitPattern: nodes[members[k]].id)
            let jitter = direction(k)
            let anchors = neighbours[k].filter { placed[$0] }
            if warm, !anchors.isEmpty {
                let centre = anchors.reduce(SIMD2<Double>.zero) { $0 + positions[$1] } / Double(anchors.count)
                positions[k] = centre + jitter * (scale * 0.05)
            } else {
                positions[k] = jitter * (spread * SplitMix64.unit(seed &+ 1).squareRoot())
            }
        }

        let settings = ForceAtlas2.Settings.inferred(nodeCount: m)
        let iterations = warm ? 80 : min(600, max(300, 150 + m / 10))
        ForceAtlas2.run(positions: &positions, edges: edges, iterations: iterations, settings: settings)

        // Normalize into the unit disk around the centroid.
        let centroid = positions.reduce(SIMD2<Double>.zero, +) / Double(m)
        var radius = 0.0
        for k in 0..<m {
            positions[k] -= centroid
            radius = max(radius, (positions[k] * positions[k]).sum().squareRoot())
        }
        if radius <= 0 { radius = 1 }
        let normalized = positions.map { SIMD2(round4($0.x / radius), round4($0.y / radius)) }
        return (normalized, State.ClusterLayout(digest: digest, scale: radius), true)
    }

    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// The cluster's most linked note of the most preferred type.
    static func label(members: [Int], input: Input, configuration: GraphConfiguration) -> String {
        func rank(_ i: Int) -> Int {
            input.nodes[i].type.flatMap { configuration.labelTypes.firstIndex(of: $0) } ?? configuration.labelTypes.count
        }
        let best = members.min { a, b in
            (rank(a), -input.inbound[a], input.nodes[a].title) < (rank(b), -input.inbound[b], input.nodes[b].title)
        }
        return best.map { input.nodes[$0].title } ?? ""
    }

    /// Bubble centres for the overview, in GraphGeometry.clusterRadius units.
    static func overviewLayout(ids: [Int64], sizes: [Int], links: [(a: Int, b: Int, weight: Double)], previous: Rows, state: inout State) -> [SIMD2<Double>] {
        let m = ids.count
        guard m > 0 else {
            state.overview = nil
            return []
        }
        let radii = sizes.map(GraphGeometry.clusterRadius)
        let gap = 0.15 * radii.reduce(0, +) / Double(m) + 1
        let old = ids.map { id -> SIMD2<Double>? in
            guard let row = previous.clusters[id], let overview = state.overview, overview.ids.contains(id) else { return nil }
            return SIMD2(row.x, row.y)
        }

        // Same clusters with similar sizes: keep the map, only resolve
        // overlaps from grown bubbles.
        if let overview = state.overview, Set(overview.ids) == Set(ids), old.allSatisfy({ $0 != nil }) {
            let oldSize = Dictionary(uniqueKeysWithValues: zip(overview.ids, overview.sizes))
            let similar = zip(ids, sizes).allSatisfy { id, size in
                let before = Double(oldSize[id] ?? 0)
                return abs(Double(size) - before) <= max(2, 0.15 * before)
            }
            if similar {
                var positions = old.map { $0! }
                separate(&positions, radii: radii, gap: gap)
                state.overview = State.Overview(ids: ids, sizes: sizes, scale: overview.scale)
                return positions.map { SIMD2(round2($0.x), round2($0.y)) }
            }
        }

        var positions = [SIMD2<Double>](repeating: .zero, count: m)
        var placed = [Bool](repeating: false, count: m)
        let oldScale = state.overview?.scale ?? 1
        for k in 0..<m {
            if let p = old[k] {
                positions[k] = p / oldScale
                placed[k] = true
            }
        }
        for k in 0..<m where !placed[k] {
            let seed = UInt64(bitPattern: ids[k])
            let angle = 2 * Double.pi * SplitMix64.unit(seed)
            let strongest = links.filter { ($0.a == k && placed[$0.b]) || ($0.b == k && placed[$0.a]) }.max { $0.weight < $1.weight }
            if let strongest {
                let other = strongest.a == k ? strongest.b : strongest.a
                positions[k] = positions[other] + SIMD2(cos(angle), sin(angle)) * 5
            } else {
                positions[k] = SIMD2(cos(angle), sin(angle)) * (20 + 20 * SplitMix64.unit(seed &+ 1))
            }
        }
        var settings = ForceAtlas2.Settings()
        settings.strongGravity = false
        settings.gravity = 0.55
        settings.scalingRatio = 40
        settings.slowDown = 5
        settings.edgeWeightInfluence = 1
        let edges = links.map { ForceAtlas2.Edge($0.a, $0.b, log2(1 + $0.weight)) }
        ForceAtlas2.run(positions: &positions, edges: edges, iterations: placed.contains(true) ? 150 : 420, settings: settings)

        // Scale so that typical neighbours just clear each other, then push
        // apart whatever still overlaps.
        var ratios: [Double] = []
        for i in 0..<m {
            var nearest: (Double, Int)?
            for j in 0..<m where j != i {
                let d = positions[i] - positions[j]
                let dist = (d * d).sum().squareRoot()
                if nearest == nil || dist < nearest!.0 { nearest = (dist, j) }
            }
            if let (dist, j) = nearest, dist > 0 { ratios.append((radii[i] + radii[j] + gap) / dist) }
        }
        ratios.sort()
        let scale = ratios.isEmpty ? 1 : ratios[ratios.count / 2]
        for k in 0..<m { positions[k] *= scale }
        pullInUnlinked(&positions, radii: radii, gap: gap, links: links)
        separate(&positions, radii: radii, gap: gap)
        let centroid = positions.reduce(SIMD2<Double>.zero, +) / Double(m)
        state.overview = State.Overview(ids: ids, sizes: sizes, scale: scale)
        return positions.map { SIMD2(round2($0.x - centroid.x), round2($0.y - centroid.y)) }
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Clusters with no link to another drift far away under repulsion;
    /// bring them to just outside the linked ones.
    static func pullInUnlinked(_ positions: inout [SIMD2<Double>], radii: [Double], gap: Double, links: [(a: Int, b: Int, weight: Double)]) {
        var linked = Set<Int>()
        for l in links {
            linked.insert(l.a)
            linked.insert(l.b)
        }
        guard !linked.isEmpty, linked.count < positions.count else { return }
        let centre = linked.reduce(SIMD2<Double>.zero) { $0 + positions[$1] } / Double(linked.count)
        let reach = linked.map { i -> Double in
            let d = positions[i] - centre
            return (d * d).sum().squareRoot() + radii[i]
        }.max() ?? 0
        for i in positions.indices where !linked.contains(i) {
            let d = positions[i] - centre
            let dist = (d * d).sum().squareRoot()
            let target = reach + radii[i] + gap
            if dist > target {
                positions[i] = centre + d / dist * target
            }
        }
    }

    /// Pushes overlapping bubbles apart.
    static func separate(_ positions: inout [SIMD2<Double>], radii: [Double], gap: Double) {
        let m = positions.count
        for _ in 0..<500 {
            var moved = false
            for i in 0..<m {
                for j in (i + 1)..<m {
                    let d = positions[j] - positions[i]
                    let dist = (d * d).sum().squareRoot()
                    let minimum = radii[i] + radii[j] + gap
                    guard dist < minimum - 1e-6 else { continue }
                    // Coincident centres: separate along a fixed direction.
                    let angle = 2 * Double.pi * SplitMix64.unit(UInt64(i * 7919 + j))
                    let direction = dist < 1e-9 ? SIMD2(cos(angle), sin(angle)) : d / dist
                    let push = direction * ((minimum - dist) / 2)
                    positions[i] -= push
                    positions[j] += push
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    /// The overview's default links: a maximum spanning forest plus each
    /// cluster's two strongest links. Returns pair keys (a < b).
    static func skeletonLinks(count: Int, links: [(a: Int, b: Int, weight: Double)]) -> Set<UInt64> {
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        var result = Set<UInt64>()
        let strongest = links.sorted { ($0.weight, $1.a, $1.b) > ($1.weight, $0.a, $0.b) }
        for l in strongest {
            let ra = find(l.a), rb = find(l.b)
            if ra != rb {
                parent[ra] = rb
                result.insert(Louvain.pairKey(l.a, l.b))
            }
        }
        var perCluster = [Int](repeating: 0, count: count)
        for l in strongest {
            if perCluster[l.a] < 2 || perCluster[l.b] < 2 {
                result.insert(Louvain.pairKey(l.a, l.b))
                perCluster[l.a] += 1
                perCluster[l.b] += 1
            }
        }
        return result
    }
}
