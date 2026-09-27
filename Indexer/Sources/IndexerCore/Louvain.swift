//
//  Louvain.swift
//  IndexerCore
//
//  Community detection for the link graph (Blondel et al. 2008): repeated
//  local moving of nodes to the neighbouring community with the best
//  modularity gain, then aggregation of each community into one node.
//
//  It can start from a previous partition. Local moving then only moves
//  nodes whose links now favour another community, so clusters (and their
//  colours and layouts on the phone) stay put across small edits instead of
//  being reshuffled by every publication.
//

import Foundation

/// Undirected weighted graph in compressed sparse row form. Every edge is
/// stored in both directions; self-loops are kept apart.
struct WeightedGraph {
    var offsets: [Int]
    var neighbors: [Int32]
    var weights: [Double]
    /// Weight of each node's self-loop (counted once).
    var selfLoops: [Double]

    var nodeCount: Int { offsets.count - 1 }

    /// `edges` must not repeat an unordered pair; `a == b` is a self-loop.
    init(nodeCount: Int, edges: [(a: Int, b: Int, weight: Double)]) {
        var degree = [Int](repeating: 0, count: nodeCount)
        var loops = [Double](repeating: 0, count: nodeCount)
        for e in edges {
            if e.a == e.b { loops[e.a] += e.weight } else {
                degree[e.a] += 1
                degree[e.b] += 1
            }
        }
        var offsets = [Int](repeating: 0, count: nodeCount + 1)
        for i in 0..<nodeCount { offsets[i + 1] = offsets[i] + degree[i] }
        var neighbors = [Int32](repeating: 0, count: offsets[nodeCount])
        var weights = [Double](repeating: 0, count: offsets[nodeCount])
        var fill = offsets
        for e in edges where e.a != e.b {
            neighbors[fill[e.a]] = Int32(e.b)
            weights[fill[e.a]] = e.weight
            fill[e.a] += 1
            neighbors[fill[e.b]] = Int32(e.a)
            weights[fill[e.b]] = e.weight
            fill[e.b] += 1
        }
        self.offsets = offsets
        self.neighbors = neighbors
        self.weights = weights
        selfLoops = loops
    }

    /// Weighted degree: incident edge weights plus twice the self-loop.
    func strength(_ i: Int) -> Double {
        var s = 2 * selfLoops[i]
        for e in offsets[i]..<offsets[i + 1] { s += weights[e] }
        return s
    }
}

enum Louvain {
    /// Community of every node, numbered densely from 0.
    ///
    /// - initial: a starting community per node (any integers; equal values
    ///   mean the same community), or nil to start from singletons.
    static func communities(_ graph: WeightedGraph, initial: [Int]? = nil, resolution: Double = 1, seed: UInt64 = 1) -> [Int] {
        let n = graph.nodeCount
        guard n > 0 else { return [] }
        var rng = SplitMix64(state: seed)
        var membership = Array(0..<n)
        var level = graph
        var community = initial.map(renumber) ?? Array(0..<n)
        for _ in 0..<32 {
            localMoving(level, community: &community, resolution: resolution, rng: &rng)
            community = renumber(community)
            for v in 0..<n { membership[v] = community[membership[v]] }
            let count = (community.max() ?? -1) + 1
            if count == level.nodeCount { break }
            level = aggregate(level, community: community, count: count)
            community = Array(0..<count)
        }
        return renumber(membership)
    }

    /// Moves nodes between communities until no move improves modularity
    /// (or a pass limit is reached).
    static func localMoving(_ g: WeightedGraph, community: inout [Int], resolution: Double, rng: inout SplitMix64) {
        let n = g.nodeCount
        let strength = (0..<n).map(g.strength)
        let total = strength.reduce(0, +)
        guard total > 0 else { return }
        var tot = [Double](repeating: 0, count: n)
        for i in 0..<n { tot[community[i]] += strength[i] }
        var linkTo = [Double](repeating: -1, count: n)
        var touched: [Int] = []
        var order = Array(0..<n)
        order.shuffle(using: &rng)
        for _ in 0..<64 {
            var moved = false
            for i in order {
                let ci = community[i]
                touched.removeAll(keepingCapacity: true)
                linkTo[ci] = 0
                touched.append(ci)
                for e in g.offsets[i]..<g.offsets[i + 1] {
                    let c = community[Int(g.neighbors[e])]
                    if linkTo[c] < 0 {
                        linkTo[c] = 0
                        touched.append(c)
                    }
                    linkTo[c] += g.weights[e]
                }
                let k = strength[i]
                tot[ci] -= k
                var best = ci
                var bestGain = linkTo[ci] - resolution * tot[ci] * k / total
                for c in touched where c != ci {
                    let gain = linkTo[c] - resolution * tot[c] * k / total
                    if gain > bestGain + 1e-12 {
                        best = c
                        bestGain = gain
                    }
                }
                tot[best] += k
                if best != ci {
                    community[i] = best
                    moved = true
                }
                for c in touched { linkTo[c] = -1 }
            }
            if !moved { break }
        }
    }

    /// One node per community; links between communities are summed.
    static func aggregate(_ g: WeightedGraph, community: [Int], count: Int) -> WeightedGraph {
        var loops = [Double](repeating: 0, count: count)
        var pairs: [UInt64: Double] = [:]
        for i in 0..<g.nodeCount {
            loops[community[i]] += g.selfLoops[i]
            for e in g.offsets[i]..<g.offsets[i + 1] {
                let j = Int(g.neighbors[e])
                guard i < j else { continue }
                let a = community[i], b = community[j]
                if a == b {
                    loops[a] += g.weights[e]
                } else {
                    pairs[pairKey(min(a, b), max(a, b)), default: 0] += g.weights[e]
                }
            }
        }
        var edges: [(a: Int, b: Int, weight: Double)] = pairs.map { (Int($0.key >> 32), Int($0.key & 0xFFFF_FFFF), $0.value) }
        edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        for (c, w) in loops.enumerated() where w > 0 { edges.append((c, c, w)) }
        return WeightedGraph(nodeCount: count, edges: edges)
    }

    static func pairKey(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    /// Relabels communities 0, 1, 2… in order of first appearance.
    static func renumber(_ community: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return community.map { c in
            if let m = map[c] { return m }
            let m = map.count
            map[c] = m
            return m
        }
    }

    /// Modularity of a partition (for tests).
    static func modularity(_ g: WeightedGraph, community: [Int]) -> Double {
        let n = g.nodeCount
        let strength = (0..<n).map(g.strength)
        let total = strength.reduce(0, +)
        guard total > 0 else { return 0 }
        var tot = [Int: Double]()
        var internalWeight = [Int: Double]()
        for i in 0..<n {
            tot[community[i], default: 0] += strength[i]
            internalWeight[community[i], default: 0] += 2 * g.selfLoops[i]
            for e in g.offsets[i]..<g.offsets[i + 1] where community[Int(g.neighbors[e])] == community[i] {
                internalWeight[community[i], default: 0] += g.weights[e]
            }
        }
        var q = 0.0
        for (c, t) in tot {
            q += (internalWeight[c] ?? 0) / total - (t / total) * (t / total)
        }
        return q
    }
}

extension SplitMix64: RandomNumberGenerator {
    /// A uniform value in [0, 1) derived from `key` alone.
    static func unit(_ key: UInt64) -> Double {
        var g = SplitMix64(state: key)
        return Double(g.next() >> 11) / Double(1 << 53)
    }
}
