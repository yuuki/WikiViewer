//
//  Leiden.swift
//  IndexerCore
//
//  Community detection for the link graph with the Leiden algorithm
//  (Traag, Waltman & van Eck 2019): fast local moving, then a refinement of
//  each community into well-connected parts, then aggregation of the
//  refined parts. Every community it returns is connected, and a community
//  that only holds together through a few bridging notes gets split.
//
//  Quality is modularity with a resolution parameter; higher resolution
//  gives smaller communities. Plain modularity (resolution 1) merged
//  unrelated topics in a vault of ~18k notes into clusters of over 1,500.
//
//  Stability across publications comes from the objective, not from the
//  starting point: `following(previous:)` adds a temporal coupling term in
//  the spirit of multislice modularity (Mucha et al. 2010), so a note gains
//  `coupling × its degree` by staying in its previous community. A move then
//  has to pay for itself. Warm-starting alone is not enough: Louvain started
//  from its previous result never splits a community, so clusters only grow
//  as the vault does, while Leiden started from its previous result keeps
//  moving hundreds of notes between near-equal optima on every run.
//

import Foundation

enum Leiden {
    /// Communities of `graph` that stay close to a previous partition.
    ///
    /// - previous: each node's previous community (any integers; equal
    ///   values mean the same community), nil for nodes not clustered
    ///   before. Nil altogether to start afresh.
    ///
    /// Previous communities get an anchor node linked to their former
    /// members with weight coupling × degree; Leiden runs on that graph
    /// until a run changes nothing.
    static func following(_ graph: WeightedGraph, previous: [Int?]?, resolution: Double, coupling: Double, seed: UInt64 = 1) -> [Int] {
        let n = graph.nodeCount
        guard let previous, previous.contains(where: { $0 != nil }) else {
            return converged(graph, initial: nil, resolution: resolution, seed: seed)
        }
        var anchor: [Int: Int] = [:]
        var edges = graph.edgeList
        var initial = [Int](repeating: 0, count: n)
        for i in 0..<n {
            guard let c = previous[i] else {
                initial[i] = -(i + 1)
                continue
            }
            let a: Int
            if let existing = anchor[c] {
                a = existing
            } else {
                a = n + anchor.count
                anchor[c] = a
            }
            edges.append((i, a, coupling * graph.strength(i)))
            initial[i] = a
        }
        let anchored = WeightedGraph(nodeCount: n + anchor.count, edges: edges)
        let start = initial + Array(n..<(n + anchor.count))
        return renumber(Array(converged(anchored, initial: start, resolution: resolution, seed: seed).prefix(n)))
    }

    /// Reruns Leiden from its own result until nothing changes: a single
    /// run can leave improvements that the next run's refinement finds.
    static func converged(_ graph: WeightedGraph, initial: [Int]?, resolution: Double, seed: UInt64 = 1) -> [Int] {
        var partition = communities(graph, initial: initial, resolution: resolution, seed: seed)
        for _ in 0..<20 {
            let next = communities(graph, initial: partition, resolution: resolution, seed: seed)
            if next == partition { break }
            partition = next
        }
        return partition
    }

    /// Community of every node, numbered densely from 0 in order of first
    /// appearance (so equal partitions give equal arrays).
    ///
    /// - initial: a starting community per node (any integers; equal values
    ///   mean the same community), or nil to start from singletons.
    static func communities(_ graph: WeightedGraph, initial: [Int]? = nil, resolution: Double = 1, seed: UInt64 = 1) -> [Int] {
        let n = graph.nodeCount
        guard n > 0 else { return [] }
        var rng = SplitMix64(state: seed)
        let total = (0..<n).reduce(0) { $0 + graph.strength($1) }
        guard total > 0 else { return Array(0..<n) }
        // Level node of every original node.
        var membership = Array(0..<n)
        var level = graph
        var partition = initial.map(renumber) ?? Array(0..<n)
        for _ in 0..<32 {
            fastLocalMoving(level, community: &partition, resolution: resolution, total: total, rng: &rng)
            partition = renumber(partition)
            let count = (partition.max() ?? -1) + 1
            if count == level.nodeCount { break }
            let refined = renumber(refine(level, partition: partition, count: count, resolution: resolution, total: total, rng: &rng))
            let refinedCount = (refined.max() ?? -1) + 1
            // Refinement merged nothing: aggregating would not change the graph.
            if refinedCount == level.nodeCount { break }
            // Each aggregate node starts in the community of its refined part.
            var next = [Int](repeating: 0, count: refinedCount)
            for v in 0..<level.nodeCount { next[refined[v]] = partition[v] }
            for v in 0..<n { membership[v] = refined[membership[v]] }
            level = level.aggregated(by: refined, count: refinedCount)
            partition = next
        }
        return renumber((0..<n).map { partition[membership[$0]] })
    }

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

    /// Visits nodes from a queue; a node whose community changes queues its
    /// neighbours outside the new community. Stops when the queue is empty.
    static func fastLocalMoving(_ g: WeightedGraph, community: inout [Int], resolution: Double, total: Double, rng: inout SplitMix64) {
        let n = g.nodeCount
        let strength = (0..<n).map(g.strength)
        var tot = [Double](repeating: 0, count: n)
        var size = [Int](repeating: 0, count: n)
        for i in 0..<n {
            tot[community[i]] += strength[i]
            size[community[i]] += 1
        }
        var empty = (0..<n).filter { size[$0] == 0 }
        var linkTo = [Double](repeating: -1, count: n)
        var touched: [Int] = []
        var queue = Array(0..<n)
        queue.shuffle(using: &rng)
        var queued = [Bool](repeating: true, count: n)
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            if head > 4096, head * 2 > queue.count {
                queue.removeFirst(head)
                head = 0
            }
            queued[i] = false
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
            size[ci] -= 1
            var best = ci
            var bestGain = linkTo[ci] - resolution * tot[ci] * k / total
            for c in touched where c != ci {
                let gain = linkTo[c] - resolution * tot[c] * k / total
                if gain > bestGain + 1e-12 {
                    best = c
                    bestGain = gain
                }
            }
            // An empty community gains 0.
            if bestGain < -1e-12 {
                if size[ci] == 0 {
                    best = ci
                } else {
                    while let c = empty.last, size[c] != 0 { empty.removeLast() }
                    if let c = empty.popLast() { best = c }
                }
            }
            tot[best] += k
            size[best] += 1
            if size[ci] == 0, best != ci { empty.append(ci) }
            if best != ci {
                community[i] = best
                for e in g.offsets[i]..<g.offsets[i + 1] {
                    let j = Int(g.neighbors[e])
                    if !queued[j], community[j] != best {
                        queued[j] = true
                        queue.append(j)
                    }
                }
            }
            for c in touched { linkTo[c] = -1 }
        }
    }

    /// Splits every community into well-connected parts: starting from
    /// singletons, a node that is well connected to its community joins the
    /// part inside it with the best quality gain, if that gain is positive.
    /// Returns a part id per node (part ids are node indices).
    static func refine(_ g: WeightedGraph, partition: [Int], count: Int, resolution: Double, total: Double, rng: inout SplitMix64) -> [Int] {
        let n = g.nodeCount
        let strength = (0..<n).map(g.strength)
        var members = [[Int]](repeating: [], count: count)
        for v in 0..<n { members[partition[v]].append(v) }
        var part = Array(0..<n)
        var partTot = strength
        // Weight from each part to the rest of its community.
        var partOut = [Double](repeating: 0, count: n)
        for v in 0..<n {
            for e in g.offsets[v]..<g.offsets[v + 1] where partition[Int(g.neighbors[e])] == partition[v] {
                partOut[v] += g.weights[e]
            }
        }
        var singleton = [Bool](repeating: true, count: n)
        var linkTo = [Double](repeating: -1, count: n)
        var touched: [Int] = []
        for c in 0..<count {
            var nodes = members[c]
            guard nodes.count > 1 else { continue }
            let communityTot = nodes.reduce(0) { $0 + strength[$1] }
            nodes.shuffle(using: &rng)
            for v in nodes where singleton[v] {
                let k = strength[v]
                guard partOut[v] >= resolution * k * (communityTot - k) / total else { continue }
                touched.removeAll(keepingCapacity: true)
                for e in g.offsets[v]..<g.offsets[v + 1] {
                    let u = Int(g.neighbors[e])
                    guard partition[u] == c else { continue }
                    let p = part[u]
                    if linkTo[p] < 0 {
                        linkTo[p] = 0
                        touched.append(p)
                    }
                    linkTo[p] += g.weights[e]
                }
                var best = -1
                var bestGain = 1e-12
                for p in touched where p != part[v] {
                    guard partOut[p] >= resolution * partTot[p] * (communityTot - partTot[p]) / total else { continue }
                    let gain = linkTo[p] - resolution * k * partTot[p] / total
                    if gain > bestGain {
                        best = p
                        bestGain = gain
                    }
                }
                if best >= 0 {
                    partOut[best] += partOut[v] - 2 * linkTo[best]
                    partTot[best] += k
                    part[v] = best
                    singleton[v] = false
                    singleton[best] = false
                }
                for p in touched { linkTo[p] = -1 }
            }
        }
        return part
    }
}
