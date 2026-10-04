//
//  WeightedGraph.swift
//  IndexerCore
//
//  The undirected weighted graph that community detection works on.
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

    /// Every edge as (a, b, weight) with a < b, then the self-loops.
    var edgeList: [(a: Int, b: Int, weight: Double)] {
        var edges: [(a: Int, b: Int, weight: Double)] = []
        for i in 0..<nodeCount {
            for e in offsets[i]..<offsets[i + 1] where i < Int(neighbors[e]) {
                edges.append((i, Int(neighbors[e]), weights[e]))
            }
        }
        for (i, w) in selfLoops.enumerated() where w > 0 { edges.append((i, i, w)) }
        return edges
    }

    /// One node per community; links between communities are summed.
    func aggregated(by community: [Int], count: Int) -> WeightedGraph {
        var loops = [Double](repeating: 0, count: count)
        var pairs: [UInt64: Double] = [:]
        for i in 0..<nodeCount {
            loops[community[i]] += selfLoops[i]
            for e in offsets[i]..<offsets[i + 1] {
                let j = Int(neighbors[e])
                guard i < j else { continue }
                let a = community[i], b = community[j]
                if a == b {
                    loops[a] += weights[e]
                } else {
                    pairs[Self.pairKey(min(a, b), max(a, b)), default: 0] += weights[e]
                }
            }
        }
        var edges: [(a: Int, b: Int, weight: Double)] = pairs.map { (Int($0.key >> 32), Int($0.key & 0xFFFF_FFFF), $0.value) }
        edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        for (c, w) in loops.enumerated() where w > 0 { edges.append((c, c, w)) }
        return WeightedGraph(nodeCount: count, edges: edges)
    }

    static func pairKey(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    /// Modularity of a partition at a resolution.
    func modularity(_ community: [Int], resolution: Double = 1) -> Double {
        let strength = (0..<nodeCount).map(strength)
        let total = strength.reduce(0, +)
        guard total > 0 else { return 0 }
        var tot = [Int: Double]()
        var internalWeight = [Int: Double]()
        for i in 0..<nodeCount {
            tot[community[i], default: 0] += strength[i]
            internalWeight[community[i], default: 0] += 2 * selfLoops[i]
            for e in offsets[i]..<offsets[i + 1] where community[Int(neighbors[e])] == community[i] {
                internalWeight[community[i], default: 0] += weights[e]
            }
        }
        return tot.reduce(0) { q, entry in
            q + (internalWeight[entry.key] ?? 0) / total - resolution * (entry.value / total) * (entry.value / total)
        }
    }
}

extension SplitMix64: RandomNumberGenerator {
    /// A uniform value in [0, 1) derived from `key` alone.
    static func unit(_ key: UInt64) -> Double {
        var g = SplitMix64(state: key)
        return Double(g.next() >> 11) / Double(1 << 53)
    }
}
