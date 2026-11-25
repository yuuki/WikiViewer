//
//  MermaidLayout.swift
//  WikiViewerKit
//
//  Lays out a MermaidFlowchart as a layered (Sugiyama-style) drawing, like
//  Mermaid's dagre layout: cycles are broken, nodes get ranks along the
//  flow, edges spanning several ranks pass through dummy points (edge
//  labels are dummies with a size, so they get room of their own), each
//  rank is ordered by barycenters to reduce crossings, and positions across
//  the flow are placed as close to their neighbours as spacing allows.
//
//  Subgraphs are laid out inside out: a subgraph's contents are laid out in
//  its own direction, and the result is one large item in its parent. An
//  edge between nodes of different subgraphs is laid out in their nearest
//  common subgraph, between the items that contain its two ends.
//
//  Text is measured by the caller, so the layout matches the font drawn.
//

import CoreGraphics
import Foundation

public struct MermaidLayout: Sendable {
    public struct Node: Sendable {
        public var label: String
        public var shape: MermaidFlowchart.Shape
        public var frame: CGRect
    }

    public struct Cluster: Sendable {
        public var title: String
        public var frame: CGRect
        /// Center of the title, at the top of the frame.
        public var titleCenter: CGPoint
    }

    public struct Edge: Sendable {
        /// From the `from` node's border to the `to` node's border.
        public var points: [CGPoint]
        public var label: String?
        public var labelFrame: CGRect?
        public var stroke: MermaidFlowchart.Stroke
        public var head: MermaidFlowchart.ArrowHead?
        public var tail: MermaidFlowchart.ArrowHead?
    }

    public var size: CGSize
    /// Outer clusters first, so inner ones are drawn on top.
    public var clusters: [Cluster]
    public var nodes: [Node]
    public var edges: [Edge]

    /// Larger charts are shown as source: laying them out on a phone takes
    /// too long, and they would be unreadable at the screen's width.
    public static let maxNodes = 400
    public static let maxEdges = 800

    /// `measure` gives the size of a (possibly multi-line) label in the
    /// font it will be drawn in, of point size `fontSize`, which also
    /// scales paddings and gaps.
    public init(chart: MermaidFlowchart, fontSize: CGFloat, measure: (String) -> CGSize) {
        self = withoutActuallyEscaping(measure) { measure in
            var engine = LayoutEngine(chart: chart, unit: fontSize, measure: measure)
            return engine.run()
        }
    }

    fileprivate init(size: CGSize, clusters: [Cluster], nodes: [Node], edges: [Edge]) {
        self.size = size
        self.clusters = clusters
        self.nodes = nodes
        self.edges = edges
    }
}

// MARK: - Structure

private enum Item: Hashable {
    case node(String)
    case cluster(String)
}

private struct ContainerResult {
    var size: CGSize
    /// Item → center, in the container's content coordinates.
    var centers: [Item: CGPoint]
    /// Edges laid out here: edge index → dummy points from the edge's
    /// `from` end to its `to` end, a label center, and whether the edge
    /// ran against the flow.
    var routes: [Int: EdgeRoute]
}

private struct EdgeRoute {
    var points: [CGPoint]
    var label: CGPoint?
    var forward: Bool
}

private struct LayoutEngine {
    let chart: MermaidFlowchart
    let unit: CGFloat
    let measure: (String) -> CGSize

    var nodeByID: [String: MermaidFlowchart.Node] = [:]
    var subgraphByID: [String: MermaidFlowchart.Subgraph] = [:]
    /// Container id (nil = top level) → its items, in order of appearance.
    var children: [String?: [Item]] = [:]
    var labelSizes: [String: CGSize] = [:]
    var results: [String?: ContainerResult] = [:]

    init(chart: MermaidFlowchart, unit: CGFloat, measure: @escaping (String) -> CGSize) {
        self.chart = chart
        self.unit = unit
        self.measure = measure
    }

    var nodePadding: CGSize { CGSize(width: unit, height: unit * 0.6) }
    var nodeGap: CGFloat { unit * 2 }
    var rankGap: CGFloat { unit * 2.6 }
    var clusterPadding: CGFloat { unit * 0.9 }
    var margin: CGFloat { 2 }

    mutating func size(of text: String) -> CGSize {
        if let cached = labelSizes[text] { return cached }
        let measured = text.isEmpty ? CGSize(width: unit, height: unit) : measure(text)
        let size = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        labelSizes[text] = size
        return size
    }

    func container(of item: Item) -> String? {
        switch item {
        case .node(let id): chart.membership[id]
        case .cluster(let id): subgraphByID[id]?.parent
        }
    }

    func item(for id: String) -> Item? {
        if nodeByID[id] != nil { return .node(id) }
        if subgraphByID[id] != nil { return .cluster(id) }
        return nil
    }

    /// Items from the top level down to `item` itself.
    func path(to item: Item) -> [Item] {
        var path = [item]
        var current = container(of: item)
        var guardCount = 0
        while let id = current, guardCount < 64 {
            path.append(.cluster(id))
            current = subgraphByID[id]?.parent
            guardCount += 1
        }
        return path.reversed()
    }

    func direction(of container: String?) -> MermaidFlowchart.Direction {
        container.flatMap { subgraphByID[$0]?.direction } ?? chart.direction
    }

    mutating func run() -> MermaidLayout {
        for node in chart.nodes { nodeByID[node.id] = node }
        for subgraph in chart.subgraphs { subgraphByID[subgraph.id] = subgraph }

        // Order items by their first node in the source, so diagrams
        // without edges keep the order they were written in.
        var firstNode: [Item: Int] = [:]
        for (index, node) in chart.nodes.enumerated() {
            for item in path(to: .node(node.id)) where firstNode[item] == nil {
                firstNode[item] = index
            }
        }
        var items: [Item] = chart.nodes.map { .node($0.id) } + chart.subgraphs.map { .cluster($0.id) }
        items.sort { (firstNode[$0] ?? Int.max) < (firstNode[$1] ?? Int.max) }
        for item in items { children[container(of: item), default: []].append(item) }

        // Edges, grouped by the container they are laid out in.
        var edgesIn: [String?: [(index: Int, from: Item, to: Item)]] = [:]
        var selfLoops: [Int] = []
        for (index, edge) in chart.edges.enumerated() {
            guard let a = item(for: edge.from), let b = item(for: edge.to) else { continue }
            if a == b {
                if case .node = a { selfLoops.append(index) }
                continue
            }
            let pa = path(to: a), pb = path(to: b)
            var k = 0
            while k < pa.count, k < pb.count, pa[k] == pb[k] { k += 1 }
            // One end contains the other: there is no line to draw.
            guard k < pa.count, k < pb.count else { continue }
            var owner: String?
            if k > 0, case .cluster(let id) = pa[k - 1] { owner = id }
            edgesIn[owner, default: []].append((index, pa[k], pb[k]))
        }

        // Inside out: deepest subgraphs first.
        let depth = Dictionary(uniqueKeysWithValues: chart.subgraphs.map { ($0.id, path(to: .cluster($0.id)).count) })
        for subgraph in chart.subgraphs.sorted(by: { depth[$0.id]! > depth[$1.id]! }) {
            results[subgraph.id] = layoutContainer(subgraph.id, edges: edgesIn[subgraph.id] ?? [])
        }
        results[nil] = layoutContainer(nil, edges: edgesIn[nil] ?? [])

        // Absolute geometry.
        var layout = MermaidLayout(size: .zero, clusters: [], nodes: [], edges: [])
        var frames: [Item: CGRect] = [:]
        var origins: [String?: CGPoint] = [nil: .zero]
        place(nil, origin: .zero, frames: &frames, origins: &origins, layout: &layout)

        var drawn: [(index: Int, edge: MermaidLayout.Edge)] = []
        for (owner, list) in edgesIn {
            guard let result = results[owner], let origin = origins[owner] else { continue }
            let flow = flowVector(direction(of: owner))
            for laid in list {
                guard let route = result.routes[laid.index],
                      let from = frames[endItem(chart.edges[laid.index].from)],
                      let to = frames[endItem(chart.edges[laid.index].to)] else { continue }
                // Along the flow, an edge leaves the upstream end on its
                // downstream side and enters the other on its upstream side.
                let upstream = route.forward ? from : to
                let downstream = route.forward ? to : from
                var points = [exit(upstream, flow)]
                let middle = route.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                points += route.forward ? middle : middle.reversed()
                points.append(entry(downstream, flow))
                if !route.forward { points.reverse() }
                let edge = chart.edges[laid.index]
                var labelFrame: CGRect?
                if let label = edge.label, !label.isEmpty, let center = route.label {
                    let s = size(of: label)
                    labelFrame = CGRect(x: center.x + origin.x - s.width / 2, y: center.y + origin.y - s.height / 2, width: s.width, height: s.height)
                }
                drawn.append((laid.index, MermaidLayout.Edge(points: points, label: edge.label, labelFrame: labelFrame,
                                                             stroke: edge.stroke, head: edge.head, tail: edge.tail)))
            }
        }
        for index in selfLoops {
            let edge = chart.edges[index]
            guard let frame = frames[.node(edge.from)] else { continue }
            let reach = unit * 1.4
            let points = [
                CGPoint(x: frame.maxX, y: frame.midY - frame.height / 4),
                CGPoint(x: frame.maxX + reach, y: frame.midY - frame.height / 4),
                CGPoint(x: frame.maxX + reach, y: frame.midY + frame.height / 4),
                CGPoint(x: frame.maxX, y: frame.midY + frame.height / 4),
            ]
            var labelFrame: CGRect?
            if let label = edge.label, !label.isEmpty {
                let s = size(of: label)
                labelFrame = CGRect(x: frame.maxX + reach + 4, y: frame.midY - s.height / 2, width: s.width, height: s.height)
            }
            drawn.append((index, MermaidLayout.Edge(points: points, label: edge.label, labelFrame: labelFrame,
                                                    stroke: edge.stroke, head: edge.head, tail: edge.tail)))
        }
        layout.edges = drawn.sorted { $0.index < $1.index }.map(\.edge)
        normalize(&layout)
        return layout
    }

    func endItem(_ id: String) -> Item {
        nodeByID[id] != nil ? .node(id) : .cluster(id)
    }

    func flowVector(_ direction: MermaidFlowchart.Direction) -> CGVector {
        switch direction {
        case .down: CGVector(dx: 0, dy: 1)
        case .up: CGVector(dx: 0, dy: -1)
        case .right: CGVector(dx: 1, dy: 0)
        case .left: CGVector(dx: -1, dy: 0)
        }
    }

    func exit(_ rect: CGRect, _ flow: CGVector) -> CGPoint {
        CGPoint(x: rect.midX + flow.dx * rect.width / 2, y: rect.midY + flow.dy * rect.height / 2)
    }

    func entry(_ rect: CGRect, _ flow: CGVector) -> CGPoint {
        CGPoint(x: rect.midX - flow.dx * rect.width / 2, y: rect.midY - flow.dy * rect.height / 2)
    }

    /// Shifts everything so the drawing starts at the margin, and sizes it.
    func normalize(_ layout: inout MermaidLayout) {
        var bounds = CGRect.null
        for node in layout.nodes { bounds = bounds.union(node.frame) }
        for cluster in layout.clusters { bounds = bounds.union(cluster.frame) }
        for edge in layout.edges {
            for point in edge.points { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            if let frame = edge.labelFrame { bounds = bounds.union(frame) }
        }
        guard !bounds.isNull else { return }
        let dx = margin - bounds.minX, dy = margin - bounds.minY
        for i in layout.nodes.indices { layout.nodes[i].frame = layout.nodes[i].frame.offsetBy(dx: dx, dy: dy) }
        for i in layout.clusters.indices {
            layout.clusters[i].frame = layout.clusters[i].frame.offsetBy(dx: dx, dy: dy)
            layout.clusters[i].titleCenter.x += dx
            layout.clusters[i].titleCenter.y += dy
        }
        for i in layout.edges.indices {
            layout.edges[i].points = layout.edges[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            layout.edges[i].labelFrame = layout.edges[i].labelFrame?.offsetBy(dx: dx, dy: dy)
        }
        layout.size = CGSize(width: (bounds.width + 2 * margin).rounded(.up), height: (bounds.height + 2 * margin).rounded(.up))
    }

    /// Records absolute frames of `container`'s items, whose content
    /// starts at `origin`, and recurses into its subgraphs.
    mutating func place(_ container: String?, origin: CGPoint, frames: inout [Item: CGRect], origins: inout [String?: CGPoint], layout: inout MermaidLayout) {
        guard let result = results[container] else { return }
        origins[container] = origin
        for item in children[container] ?? [] {
            guard let center = result.centers[item] else { continue }
            let s = itemSize(item)
            let frame = CGRect(x: origin.x + center.x - s.width / 2, y: origin.y + center.y - s.height / 2, width: s.width, height: s.height)
            frames[item] = frame
            switch item {
            case .node(let id):
                guard let node = nodeByID[id] else { continue }
                layout.nodes.append(MermaidLayout.Node(label: node.label, shape: node.shape, frame: frame))
            case .cluster(let id):
                guard let subgraph = subgraphByID[id], let inner = results[id] else { continue }
                let title = titleHeight(subgraph)
                layout.clusters.append(MermaidLayout.Cluster(
                    title: subgraph.title, frame: frame,
                    titleCenter: CGPoint(x: frame.midX, y: frame.minY + clusterPadding / 2 + title / 2)))
                let contentOrigin = CGPoint(x: frame.minX + (frame.width - inner.size.width) / 2,
                                            y: frame.minY + clusterPadding + title)
                place(id, origin: contentOrigin, frames: &frames, origins: &origins, layout: &layout)
            }
        }
    }

    func titleHeight(_ subgraph: MermaidFlowchart.Subgraph) -> CGFloat {
        subgraph.title.isEmpty ? 0 : (labelSizes[subgraph.title]?.height ?? unit) + unit * 0.4
    }

    mutating func itemSize(_ item: Item) -> CGSize {
        switch item {
        case .node(let id):
            guard let node = nodeByID[id] else { return .zero }
            return nodeSize(node)
        case .cluster(let id):
            guard let subgraph = subgraphByID[id] else { return .zero }
            let inner = results[id]?.size ?? .zero
            let title = subgraph.title.isEmpty ? .zero : size(of: subgraph.title)
            return CGSize(width: max(inner.width, title.width) + 2 * clusterPadding,
                          height: inner.height + titleHeight(subgraph) + 2 * clusterPadding)
        }
    }

    mutating func nodeSize(_ node: MermaidFlowchart.Node) -> CGSize {
        let text = size(of: node.label)
        let w = text.width + 2 * nodePadding.width
        let h = text.height + 2 * nodePadding.height
        switch node.shape {
        case .rectangle, .rounded:
            return CGSize(width: w, height: h)
        case .stadium:
            return CGSize(width: w + h / 2, height: h)
        case .subroutine:
            return CGSize(width: w + unit, height: h)
        case .cylinder:
            return CGSize(width: w, height: h + unit)
        case .circle:
            let d = (text.width * text.width + text.height * text.height).squareRoot() + nodePadding.height * 2
            return CGSize(width: d, height: d)
        case .doubleCircle:
            let d = (text.width * text.width + text.height * text.height).squareRoot() + nodePadding.height * 2 + unit * 0.6
            return CGSize(width: d, height: d)
        case .rhombus:
            // The label's box fits inside: w/W + h/H ≤ 1 with W = w + 2h.
            let width = w + 2 * h
            return CGSize(width: width, height: max(h * 1.6, width / 2))
        case .hexagon, .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt:
            return CGSize(width: w + h, height: h)
        case .asymmetric:
            return CGSize(width: w + h / 2, height: h)
        }
    }

    // MARK: - Layered layout of one container

    mutating func layoutContainer(_ container: String?, edges: [(index: Int, from: Item, to: Item)]) -> ContainerResult {
        let items = children[container] ?? []
        let direction = direction(of: container)
        let vertical = direction == .down || direction == .up
        let sizes = items.map { itemSize($0) }
        // Along the flow and across it.
        let along = sizes.map { vertical ? $0.height : $0.width }
        let across = sizes.map { vertical ? $0.width : $0.height }
        let indexOf = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1, $0) })
        let n = items.count

        var pairs: [(u: Int, v: Int, edge: Int)] = []
        for edge in edges {
            guard let u = indexOf[edge.from], let v = indexOf[edge.to], u != v else { continue }
            pairs.append((u, v, edge.index))
        }

        // Break cycles: edges back to a node on the DFS stack are reversed.
        var reversed = Set<Int>()
        var outgoing = Array(repeating: [Int](), count: n)
        for (i, pair) in pairs.enumerated() { outgoing[pair.u].append(i) }
        var state = Array(repeating: 0, count: n) // 0 new, 1 on stack, 2 done
        for root in 0..<n where state[root] == 0 {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                if top.next < outgoing[top.node].count {
                    stack[stack.count - 1].next += 1
                    let pairIndex = outgoing[top.node][top.next]
                    let v = pairs[pairIndex].v
                    if state[v] == 1 {
                        reversed.insert(pairIndex)
                    } else if state[v] == 0 {
                        state[v] = 1
                        stack.append((v, 0))
                    }
                } else {
                    state[top.node] = 2
                    stack.removeLast()
                }
            }
        }
        let oriented = pairs.enumerated().map { i, p in reversed.contains(i) ? (u: p.v, v: p.u, edge: p.edge, forward: false) : (u: p.u, v: p.v, edge: p.edge, forward: true) }

        // Longest-path ranks, then sources pulled down next to their targets.
        var preds = Array(repeating: [Int](), count: n)
        var succs = Array(repeating: [Int](), count: n)
        for e in oriented {
            succs[e.u].append(e.v)
            preds[e.v].append(e.u)
        }
        var rank = Array(repeating: 0, count: n)
        var indegree = preds.map(\.count)
        var queue = (0..<n).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let u = queue[head]
            head += 1
            for v in succs[u] {
                rank[v] = max(rank[v], rank[u] + 1)
                indegree[v] -= 1
                if indegree[v] == 0 { queue.append(v) }
            }
        }
        for u in 0..<n where preds[u].isEmpty && !succs[u].isEmpty {
            rank[u] = max(rank[u], (succs[u].map { rank[$0] }.min() ?? 1) - 1)
        }

        // Ranks are doubled so every edge has a dummy between its ends;
        // a label sits on its edge's middle dummy.
        struct VNode {
            var along: CGFloat
            var across: CGFloat
            var real: Bool
            var key: Double
        }
        var vnodes = (0..<n).map { VNode(along: along[$0], across: across[$0], real: true, key: Double($0)) }
        var layerOf = rank.map { $0 * 2 }
        var vpreds = Array(repeating: [Int](), count: n)
        var vsuccs = Array(repeating: [Int](), count: n)
        var chains: [(edge: Int, forward: Bool, dummies: [Int], label: Int?)] = []
        for e in oriented {
            let label = chart.edges[e.edge].label.flatMap { $0.isEmpty ? nil : $0 }
            let labelSize = label.map { size(of: $0) }
            var previous = e.u
            var dummies: [Int] = []
            let span = layerOf[e.v] - layerOf[e.u]
            let labelAt = (span - 1) / 2
            for step in 1..<max(span, 1) {
                let id = vnodes.count
                let isLabel = labelSize != nil && step - 1 == labelAt
                let s = isLabel ? labelSize! : .zero
                vnodes.append(VNode(along: vertical ? s.height : s.width, across: vertical ? s.width : s.height,
                                    real: isLabel, key: Double(e.u) + 0.5))
                layerOf.append(layerOf[e.u] + step)
                vpreds.append([previous])
                vsuccs.append([])
                vsuccs[previous].append(id)
                dummies.append(id)
                previous = id
            }
            vsuccs[previous].append(e.v)
            vpreds[e.v].append(previous)
            chains.append((e.edge, e.forward, dummies, labelSize != nil && !dummies.isEmpty ? dummies[labelAt] : nil))
        }

        let layerCount = (layerOf.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: layerCount)
        for v in vnodes.indices { layers[layerOf[v]].append(v) }
        for l in layers.indices { layers[l].sort { vnodes[$0].key < vnodes[$1].key } }

        // Barycenter ordering, keeping the order with the fewest crossings.
        func positions(_ layers: [[Int]]) -> [Int] {
            var position = Array(repeating: 0, count: vnodes.count)
            for layer in layers { for (i, v) in layer.enumerated() { position[v] = i } }
            return position
        }
        func crossings(_ layers: [[Int]]) -> Int {
            let position = positions(layers)
            var total = 0
            for l in 0..<max(layers.count - 1, 0) {
                var segments: [(Int, Int)] = []
                for u in layers[l] { for v in vsuccs[u] { segments.append((position[u], position[v])) } }
                for i in segments.indices {
                    for j in (i + 1)..<segments.count {
                        let a = segments[i], b = segments[j]
                        if (a.0 < b.0 && a.1 > b.1) || (a.0 > b.0 && a.1 < b.1) { total += 1 }
                    }
                }
            }
            return total
        }
        var best = layers
        var bestCrossings = crossings(layers)
        if bestCrossings > 0 {
            for iteration in 0..<16 {
                let down = iteration % 2 == 0
                var position = positions(layers)
                let order = down ? Array(1..<layerCount) : Array((0..<max(layerCount - 1, 0)).reversed())
                for l in order {
                    let bary: [Int: Double] = Dictionary(uniqueKeysWithValues: layers[l].map { v in
                        let neighbours = down ? vpreds[v] : vsuccs[v]
                        let value = neighbours.isEmpty ? Double(position[v]) : Double(neighbours.map { position[$0] }.reduce(0, +)) / Double(neighbours.count)
                        return (v, value)
                    })
                    layers[l].sort { (bary[$0]!, position[$0]) < (bary[$1]!, position[$1]) }
                    for (i, v) in layers[l].enumerated() { position[v] = i }
                }
                let count = crossings(layers)
                if count < bestCrossings {
                    best = layers
                    bestCrossings = count
                    if count == 0 { break }
                }
            }
        }
        layers = best

        // Positions across the flow: each layer as close as spacing allows
        // to the mean of its neighbours in the previous layer.
        var x = Array(repeating: CGFloat(0), count: vnodes.count)
        func gap(_ a: Int, _ b: Int) -> CGFloat {
            let separation = vnodes[a].real && vnodes[b].real ? nodeGap : nodeGap / 2
            return (vnodes[a].across + vnodes[b].across) / 2 + separation
        }
        for layer in layers {
            var cursor: CGFloat = 0
            for (i, v) in layer.enumerated() {
                if i > 0 { cursor += gap(layer[i - 1], v) }
                x[v] = cursor
            }
        }
        for iteration in 0..<12 {
            let down = iteration % 2 == 0
            let order = down ? Array(1..<max(layerCount, 1)) : Array((0..<max(layerCount - 1, 0)).reversed())
            for l in order {
                let layer = layers[l]
                guard !layer.isEmpty else { continue }
                let desired = layer.map { v -> CGFloat in
                    let neighbours = iteration >= 10 ? vpreds[v] + vsuccs[v] : (down ? vpreds[v] : vsuccs[v])
                    return neighbours.isEmpty ? x[v] : neighbours.map { x[$0] }.reduce(0, +) / CGFloat(neighbours.count)
                }
                let gaps = (0..<layer.count).map { $0 == 0 ? 0 : gap(layer[$0 - 1], layer[$0]) }
                let placed = Self.isotonic(desired: desired, gaps: gaps)
                for (i, v) in layer.enumerated() { x[v] = placed[i] }
            }
        }

        // Positions along the flow.
        var extent = Array(repeating: CGFloat(0), count: layerCount)
        for v in vnodes.indices { extent[layerOf[v]] = max(extent[layerOf[v]], vnodes[v].along) }
        var center = Array(repeating: CGFloat(0), count: layerCount)
        for l in 0..<layerCount {
            center[l] = l == 0 ? extent[0] / 2 : center[l - 1] + extent[l - 1] / 2 + rankGap / 2 + extent[l] / 2
        }
        let minX = vnodes.indices.map { x[$0] - vnodes[$0].across / 2 }.min() ?? 0
        let maxX = vnodes.indices.map { x[$0] + vnodes[$0].across / 2 }.max() ?? 0
        let length = layerCount == 0 ? 0 : center[layerCount - 1] + extent[layerCount - 1] / 2
        let width = maxX - minX
        func point(_ v: Int) -> CGPoint {
            let a = center[layerOf[v]], c = x[v] - minX
            switch direction {
            case .down: return CGPoint(x: c, y: a)
            case .up: return CGPoint(x: c, y: length - a)
            case .right: return CGPoint(x: a, y: c)
            case .left: return CGPoint(x: length - a, y: c)
            }
        }

        var result = ContainerResult(size: vertical ? CGSize(width: width, height: length) : CGSize(width: length, height: width), centers: [:], routes: [:])
        for (i, item) in items.enumerated() { result.centers[item] = point(i) }
        for chain in chains {
            result.routes[chain.edge] = EdgeRoute(points: chain.dummies.map(point), label: chain.label.map(point), forward: chain.forward)
        }
        return result
    }

    /// Positions closest (least squares) to `desired`, in order, with each
    /// at least `gaps[i]` after the previous: pool adjacent violators.
    static func isotonic(desired: [CGFloat], gaps: [CGFloat]) -> [CGFloat] {
        var offset = Array(repeating: CGFloat(0), count: desired.count)
        for i in desired.indices.dropFirst() { offset[i] = offset[i - 1] + gaps[i] }
        var blocks: [(sum: CGFloat, count: Int)] = []
        for i in desired.indices {
            blocks.append((desired[i] - offset[i], 1))
            while blocks.count > 1 {
                let last = blocks[blocks.count - 1], previous = blocks[blocks.count - 2]
                guard previous.sum / CGFloat(previous.count) > last.sum / CGFloat(last.count) else { break }
                blocks.removeLast(2)
                blocks.append((previous.sum + last.sum, previous.count + last.count))
            }
        }
        var result: [CGFloat] = []
        for block in blocks {
            let mean = block.sum / CGFloat(block.count)
            for _ in 0..<block.count { result.append(mean + offset[result.count]) }
        }
        return result
    }
}
