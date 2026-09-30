//
//  ForceLayout.swift
//  IndexerCore
//
//  ForceAtlas2 (Jacomy et al. 2014), following graphology's implementation:
//  degree-weighted repulsion, linear attraction along links, gravity towards
//  the origin and per-node adaptive speed. Repulsion uses a Barnes-Hut
//  quadtree above a few hundred nodes, so a cluster of thousands of notes
//  lays out in about a second on the Mac.
//

import Foundation

struct ForceAtlas2 {
    struct Settings {
        var scalingRatio = 10.0
        var gravity = 0.05
        /// Gravity proportional to distance (graphology's strongGravityMode):
        /// keeps loosely connected parts close to the rest.
        var strongGravity = true
        var slowDown = 1.0
        var barnesHutTheta = 1.2
        var barnesHutThreshold = 300
        /// Exponent applied to link weights.
        var edgeWeightInfluence = 1.0
        /// Longest move of a node in one step. Two hubs that start almost on
        /// top of each other repel each other with a force of millions; left
        /// unbounded, the move overshoots, gravity throws the node back
        /// further still, and the layout diverges.
        var maximumStep = Double.infinity

        /// graphology's inferSettings for a graph of `n` nodes, with steps
        /// bounded to a tenth of the layout's extent (about 10√n).
        static func inferred(nodeCount n: Int) -> Settings {
            var s = Settings()
            s.slowDown = 1 + log(Double(max(n, 1)))
            s.maximumStep = Double(max(n, 1)).squareRoot()
            return s
        }
    }

    typealias Edge = (a: Int, b: Int, weight: Double)

    /// Runs `iterations` steps in place. Mass is 1 + degree.
    static func run(positions: inout [SIMD2<Double>], edges: [Edge], iterations: Int, settings: Settings) {
        let n = positions.count
        guard n > 1 else { return }
        var mass = [Double](repeating: 1, count: n)
        for e in edges where e.a != e.b {
            mass[e.a] += 1
            mass[e.b] += 1
        }
        let edgeWeights = edges.map { settings.edgeWeightInfluence == 1 ? $0.weight : pow($0.weight, settings.edgeWeightInfluence) }
        var force = [SIMD2<Double>](repeating: .zero, count: n)
        var oldForce = force
        var convergence = [Double](repeating: 1, count: n)
        let useTree = n > settings.barnesHutThreshold
        var tree = QuadTree()

        for _ in 0..<iterations {
            swap(&force, &oldForce)
            for i in 0..<n { force[i] = .zero }

            // Repulsion.
            if useTree {
                tree.build(positions: positions, mass: mass)
                for i in 0..<n {
                    force[i] += tree.repulsion(on: i, position: positions[i], mass: mass[i], coefficient: settings.scalingRatio, theta: settings.barnesHutTheta)
                }
            } else {
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        let d = positions[i] - positions[j]
                        let d2 = (d * d).sum()
                        guard d2 > 0 else { continue }
                        let f = d * (settings.scalingRatio * mass[i] * mass[j] / d2)
                        force[i] += f
                        force[j] -= f
                    }
                }
            }

            // Gravity.
            for i in 0..<n {
                let p = positions[i]
                if settings.strongGravity {
                    force[i] -= p * (settings.scalingRatio * mass[i] * settings.gravity)
                } else {
                    let distance = (p * p).sum().squareRoot()
                    if distance > 0 { force[i] -= p * (settings.scalingRatio * mass[i] * settings.gravity / distance) }
                }
            }

            // Attraction along links.
            for (k, e) in edges.enumerated() where e.a != e.b {
                let d = positions[e.a] - positions[e.b]
                let f = d * -edgeWeights[k]
                force[e.a] += f
                force[e.b] -= f
            }

            // Adaptive per-node speed (graphology's non-adjustSizes branch).
            for i in 0..<n {
                let f = force[i], old = oldForce[i]
                let swingVector = old - f
                let swinging = mass[i] * (swingVector * swingVector).sum().squareRoot()
                let tractionVector = old + f
                let traction = (tractionVector * tractionVector).sum().squareRoot() / 2
                let speed = convergence[i] * log(1 + traction) / (1 + swinging.squareRoot())
                convergence[i] = min(1, (speed * (f * f).sum() / (1 + swinging.squareRoot())).squareRoot())
                var step = f * (speed / settings.slowDown)
                let length = (step * step).sum().squareRoot()
                if length > settings.maximumStep { step *= settings.maximumStep / length }
                positions[i] += step
            }
        }
    }
}

/// Barnes-Hut quadtree over point masses, rebuilt every iteration.
struct QuadTree {
    private struct Cell {
        var center: SIMD2<Double>
        var half: Double
        var mass = 0.0
        var massCenter = SIMD2<Double>.zero
        /// Index of the first of four children, or -1 for a leaf.
        var firstChild = -1
        /// Body in a leaf, or -1. A leaf at maximum depth may hold the
        /// aggregate of several coincident bodies.
        var body = -1
    }

    private var cells: [Cell] = []
    private var positions: [SIMD2<Double>] = []
    private var mass: [Double] = []
    private static let maximumDepth = 48

    mutating func build(positions: [SIMD2<Double>], mass: [Double]) {
        self.positions = positions
        self.mass = mass
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for p in positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        let half = max(max(hi.x - lo.x, hi.y - lo.y) / 2, 1e-9) * 1.0001
        cells.removeAll(keepingCapacity: true)
        cells.append(Cell(center: (lo + hi) / 2, half: half))
        for i in positions.indices { insert(i, cell: 0, depth: 0) }
    }

    private mutating func insert(_ body: Int, cell: Int, depth: Int) {
        var cell = cell, depth = depth
        while true {
            let p = positions[body], m = mass[body]
            let total = cells[cell].mass + m
            cells[cell].massCenter = (cells[cell].massCenter * cells[cell].mass + p * m) / total
            cells[cell].mass = total
            if cells[cell].firstChild >= 0 {
                cell = cells[cell].firstChild + quadrant(p, of: cells[cell].center)
                depth += 1
                continue
            }
            if cells[cell].mass == m {
                // Was empty.
                cells[cell].body = body
                return
            }
            if depth >= Self.maximumDepth {
                // Coincident bodies: keep the aggregate in this leaf.
                return
            }
            // Split the leaf and push its body down one level.
            let existing = cells[cell].body
            let first = cells.count
            let h = cells[cell].half / 2
            let c = cells[cell].center
            for q in 0..<4 {
                let offset = SIMD2<Double>(q & 1 == 0 ? -h : h, q & 2 == 0 ? -h : h)
                cells.append(Cell(center: c + offset, half: h))
            }
            cells[cell].firstChild = first
            cells[cell].body = -1
            if existing >= 0 {
                let child = first + quadrant(positions[existing], of: c)
                cells[child].mass = mass[existing]
                cells[child].massCenter = positions[existing]
                cells[child].body = existing
            }
            cell = first + quadrant(p, of: c)
            depth += 1
        }
    }

    private func quadrant(_ p: SIMD2<Double>, of center: SIMD2<Double>) -> Int {
        (p.x < center.x ? 0 : 1) | (p.y < center.y ? 0 : 2)
    }

    func repulsion(on body: Int, position p: SIMD2<Double>, mass m: Double, coefficient: Double, theta: Double) -> SIMD2<Double> {
        var force = SIMD2<Double>.zero
        var stack = [0]
        let theta2 = theta * theta
        while let index = stack.popLast() {
            let cell = cells[index]
            guard cell.mass > 0, cell.body != body || cell.firstChild >= 0 else { continue }
            let d = p - cell.massCenter
            let d2 = (d * d).sum()
            let size = cell.half * 2
            if cell.firstChild < 0 || size * size < theta2 * d2 {
                guard d2 > 0 else { continue }
                var cellMass = cell.mass
                if cell.body == body { cellMass -= m }
                force += d * (coefficient * m * cellMass / d2)
            } else {
                stack.append(contentsOf: cell.firstChild..<(cell.firstChild + 4))
            }
        }
        return force
    }
}
