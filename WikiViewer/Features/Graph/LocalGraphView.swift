//
//  LocalGraphView.swift
//  WikiViewer
//
//  A note's neighbourhood in concentric rings (wiki-lens's Local Lens):
//  the note in the middle, its most relevant links around it, the notes
//  those lead to further out, and links to notes that do not exist yet as
//  dashed red rings where the trail breaks off. "Center Here" walks the
//  graph without leaving the screen; the rings rearrange in place.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct LocalGraphView: View {
    let path: String
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute
    @AppStorage(GraphPreferences.colorModeKey) private var colorMode: GraphColorMode = .type
    @AppStorage(GraphPreferences.hiddenTypesKey) private var hiddenTypes = ""
    @State private var centerPath: String?
    @State private var graph: LocalGraph?
    @State private var types: [GraphType] = []
    @State private var failed = false
    @State private var selection: Int64?
    @State private var positions: [Int64: CGPoint] = [:]
    @State private var transition: Transition?

    /// Positions before and after a re-centring, interpolated over `duration`.
    struct Transition: Equatable {
        var from: [Int64: CGPoint]
        var start: Date
        var duration = 0.5
    }

    private var current: String { centerPath ?? path }

    var body: some View {
        content
            .navigationTitle(graph?.center.title ?? VaultPath.basename(of: current))
            .navigationSubtitle(Text("Local Graph"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    GraphDisplayMenu(types: types)
                    if let cluster = graph?.center.cluster {
                        Button("Show in Cluster", systemImage: "circle.hexagongrid") {
                            openRoute(.graphCluster(id: cluster, focus: current))
                        }
                    }
                }
            }
            .task(id: TaskKey(session: library.session?.id, path: current)) { await load() }
            .task(id: transition) {
                guard let transition else { return }
                try? await Task.sleep(for: .seconds(transition.duration))
                if self.transition == transition { self.transition = nil }
            }
    }

    private struct TaskKey: Equatable {
        var session: String?
        var path: String
    }

    private var effectiveColorMode: GraphColorMode {
        colorMode == .type && types.isEmpty ? .cluster : colorMode
    }

    @ViewBuilder
    private var content: some View {
        if let graph {
            TimelineView(.animation(paused: transition == nil)) { timeline in
                GraphCanvas(scene: scene(graph, at: timeline.date), selection: selection, fitKey: 0, labelBudget: 48,
                            onDoubleClick: { open($0, in: graph) }) { tapped in
                    withAnimation(.snappy) { selection = tapped }
                }
            }
            .accessibilityLabel(Text("Local graph of \(graph.center.title) with \(graph.members.count - 1) linked notes"))
            .graphCard(empty: selection == nil, placeholder: "Click a note to see what it links to. Double-click opens it.") {
                card(graph)
            }
        } else if failed {
            ContentUnavailableView("Not in Snapshot", systemImage: "doc.questionmark", description: Text("\(current) is not in the current snapshot."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Scene

    /// Missing link targets get negative ids.
    private func missingID(_ index: Int) -> Int64 { -1 - Int64(index) }

    private func visibleMembers(_ graph: LocalGraph) -> [LocalGraph.Member] {
        let hidden = GraphPreferences.decode(hiddenTypes)
        guard !hidden.isEmpty else { return graph.members }
        return graph.members.filter { $0.depth == 0 || ($0.node.type.map { !hidden.contains($0) } ?? true) }
    }

    private func scene(_ graph: LocalGraph, at date: Date) -> GraphScene {
        let mode = effectiveColorMode
        var progress: CGFloat = 1
        if let transition {
            let t = min(max(date.timeIntervalSince(transition.start) / transition.duration, 0), 1)
            progress = 1 - pow(1 - t, 3)
        }
        func position(_ id: Int64) -> CGPoint {
            let target = positions[id] ?? .zero
            guard let transition, progress < 1 else { return target }
            // Newcomers grow out of the new centre's old position.
            let start = transition.from[id] ?? transition.from[graph.center.id] ?? .zero
            return CGPoint(x: start.x + (target.x - start.x) * progress, y: start.y + (target.y - start.y) * progress)
        }
        var nodes: [GraphScene.Node] = []
        for m in visibleMembers(graph) {
            let isCenter = m.depth == 0
            nodes.append(GraphScene.Node(
                id: m.node.id, position: position(m.node.id),
                radius: isCenter ? 11 : m.node.screenRadius,
                color: GraphPalette.color(for: m.node, mode: mode), label: m.node.title,
                priority: isCenter ? .infinity : (m.depth == 1 ? 1_000_000 : 0) + m.score,
                style: isCenter ? .center : .dot))
        }
        var edges = graph.edges.map { GraphScene.Edge(a: $0.a, b: $0.b, width: 0.8) }
        for (i, target) in graph.missing.enumerated() {
            let id = missingID(i)
            nodes.append(GraphScene.Node(id: id, position: position(id), radius: 6, color: GraphPalette.missing,
                                         label: target, priority: 500, style: .missing))
            edges.append(GraphScene.Edge(a: graph.center.id, b: id, width: 0.8))
        }
        return GraphScene(nodes: nodes, edges: edges)
    }

    /// Concentric rings: direct links on the first, ordered by relevance;
    /// missing notes after them; second-degree notes on the outer ring,
    /// ordered by the angle of the note they are reached through so that
    /// links cross as little as possible.
    static func layout(_ graph: LocalGraph, missing: [Int64]) -> [Int64: CGPoint] {
        var result: [Int64: CGPoint] = [graph.center.id: .zero]
        let first = graph.members.filter { $0.depth == 1 }.map(\.id) + missing
        var angle: [Int64: Double] = [:]
        func place(_ ids: [Int64], radius: Double, offset: Double) {
            let n = ids.count
            guard n > 0 else { return }
            for (i, id) in ids.enumerated() {
                let a = -Double.pi / 2 + offset + 2 * Double.pi * Double(i) / Double(n)
                // Alternate radii on a crowded ring to give labels room.
                let r = n > 10 && i % 2 == 1 ? radius * 1.2 : radius
                angle[id] = a
                result[id] = CGPoint(x: cos(a) * r, y: sin(a) * r)
            }
        }
        place(first, radius: 1.25, offset: 0)
        let second = graph.members.filter { $0.depth == 2 }
            .sorted { (angle[$0.parent ?? 0] ?? 0, -$0.score) < (angle[$1.parent ?? 0] ?? 0, -$1.score) }
        // Start the outer ring beside the first one's parent.
        let start = second.first?.parent.flatMap { angle[$0] } ?? -Double.pi / 2
        place(second.map(\.id), radius: 2.3, offset: start + Double.pi / 2)
        return result
    }

    /// A note opens; a missing one shows what links to it.
    private func open(_ id: Int64, in graph: LocalGraph) {
        if id < 0 {
            let index = Int(-1 - id)
            if graph.missing.indices.contains(index) { openRoute(.missing(target: graph.missing[index])) }
        } else if let member = graph.members.first(where: { $0.id == id }) {
            openRoute(.note(path: member.node.path, anchor: nil))
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ graph: LocalGraph) -> some View {
        if let selection, selection < 0 {
            let index = Int(-1 - selection)
            if graph.missing.indices.contains(index) {
                let target = graph.missing[index]
                GraphCard(onClose: { withAnimation(.snappy) { self.selection = nil } }) {
                    HStack(spacing: 10) {
                        Circle().strokeBorder(GraphPalette.missing, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 12, height: 12)
                        Text(target).chromeFont(.headline).lineLimit(2).padding(.trailing, 28)
                    }
                    Text("Linked from this note, but there is no note by that name yet.")
                        .chromeFont(.caption).foregroundStyle(.secondary)
                    Button("Show Details", systemImage: "doc.questionmark") {
                        openRoute(.missing(target: target))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        } else if let selection, let member = graph.members.first(where: { $0.id == selection }) {
            let node = member.node
            NodeCard(node: node, color: GraphPalette.color(for: node, mode: effectiveColorMode),
                     secondary: member.depth == 0 ? [] : [.init(title: "Center Here", systemImage: "scope") { recenter(on: node.path) }],
                     onOpen: { openRoute(.note(path: node.path, anchor: nil)) },
                     onNeighbour: { neighbour in
                         if graph.members.contains(where: { $0.id == neighbour.id }) {
                             withAnimation(.snappy) { self.selection = neighbour.id }
                         } else {
                             recenter(on: neighbour.path)
                         }
                     },
                     onClose: { withAnimation(.snappy) { self.selection = nil } })
                .id(node.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func recenter(on path: String) {
        selection = nil
        centerPath = path
    }

    private func load() async {
        guard let session = library.session else { return }
        if types.isEmpty { types = (try? await session.graph.types()) ?? [] }
        guard let node = try? await session.graph.node(path: current),
              let loaded = try? await session.graph.localGraph(of: node.id) else {
            graph = nil
            failed = true
            return
        }
        failed = false
        let previous = positions
        let newPositions = Self.layout(loaded, missing: loaded.missing.indices.map(missingID))
        if graph != nil, !previous.isEmpty {
            transition = Transition(from: previous, start: .now)
        }
        positions = newPositions
        graph = loaded
    }
}
