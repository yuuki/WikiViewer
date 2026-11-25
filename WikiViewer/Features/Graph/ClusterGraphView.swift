//
//  ClusterGraphView.swift
//  WikiViewer
//
//  One cluster's notes in the layout the Mac computed for it. Only the most
//  linked notes are loaded (GraphRepository.clusterNodeLimit), so a cluster
//  of thousands of notes still draws smoothly; pinch to read more names.
//  Selecting a note shows its links; its card leads to the note, its local
//  graph, or across to a neighbour in another cluster.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct ClusterGraphView: View {
    let id: Int64
    /// Path of a note to select and zoom to on arrival.
    let focus: String?
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute
    @AppStorage(GraphPreferences.colorModeKey) private var colorMode: GraphColorMode = .type
    @AppStorage(GraphPreferences.hiddenTypesKey) private var hiddenTypes = ""
    @AppStorage("WikiViewer.graph.clusterAsList") private var showsList = false
    @State private var graph: ClusterGraph?
    @State private var types: [GraphType] = []
    @State private var missing = false
    @State private var selection: Int64?
    @State private var focusNode: Int64?

    var body: some View {
        content
            .navigationTitle(graph?.cluster.label ?? String(localized: "Cluster"))
            .navigationSubtitle(subtitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    GraphDisplayMenu(types: types)
                    Button(showsList ? "Map" : "List", systemImage: showsList ? "circle.hexagongrid" : "list.bullet") {
                        showsList.toggle()
                    }
                }
            }
            .task(id: library.session?.id) { await load() }
    }

    private var subtitle: Text {
        guard let graph else { return Text(verbatim: "") }
        if graph.isTruncated {
            return Text("Most linked \(graph.nodes.count) of \(graph.cluster.size) notes")
        }
        return Text("\(graph.cluster.size) notes")
    }

    /// Colour by type only if the graph has types.
    private var effectiveColorMode: GraphColorMode {
        colorMode == .type && types.isEmpty ? .cluster : colorMode
    }

    @ViewBuilder
    private var content: some View {
        if let graph {
            if showsList {
                memberList(graph)
            } else {
                map(graph)
            }
        } else if missing {
            ContentUnavailableView("Cluster Not Found", systemImage: "circle.hexagongrid",
                                   description: Text("The graph changed with the latest snapshot. Go back to the overview to find the notes again."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func visible(_ graph: ClusterGraph) -> [GraphNode] {
        let hidden = GraphPreferences.decode(hiddenTypes)
        guard !hidden.isEmpty else { return graph.nodes }
        return graph.nodes.filter { $0.type.map { !hidden.contains($0) } ?? true || $0.id == selection }
    }

    /// The note the cluster is named after heads the list.
    private func centerFirst(_ nodes: [GraphNode], _ graph: ClusterGraph) -> [GraphNode] {
        guard let i = nodes.firstIndex(where: { $0.id == graph.centerID }) else { return nodes }
        var result = nodes
        result.insert(result.remove(at: i), at: 0)
        return result
    }

    private func scene(_ graph: ClusterGraph) -> GraphScene {
        let mode = effectiveColorMode
        // The note the cluster is named after is drawn like a local graph's
        // centre: larger, ringed, and always named first.
        let nodes = visible(graph).map { n in
            let isCenter = n.id == graph.centerID
            return GraphScene.Node(id: n.id, position: CGPoint(x: n.x, y: -n.y), radius: isCenter ? 11 : n.screenRadius,
                                   color: GraphPalette.color(for: n, mode: mode), label: n.title,
                                   priority: isCenter ? .infinity : n.labelPriority, style: isCenter ? .center : .dot)
        }
        let ids = Set(nodes.map(\.id))
        let edges = graph.edges.filter { ids.contains($0.a) && ids.contains($0.b) }.map { GraphScene.Edge(a: $0.a, b: $0.b) }
        return GraphScene(nodes: nodes, edges: edges)
    }

    private func map(_ graph: ClusterGraph) -> some View {
        GraphCanvas(scene: scene(graph), selection: selection, fitKey: graph.cluster.id, focus: focusNode, labelBudget: 28,
                    onDoubleClick: { id in
                        if let node = graph.nodes.first(where: { $0.id == id }) { openRoute(.note(path: node.path, anchor: nil)) }
                    }) { tapped in
            withAnimation(.snappy) { selection = tapped }
        }
        .accessibilityLabel(Text("Map of \(graph.nodes.count) notes"))
        .accessibilityHint(Text("Switch to the list to browse notes with VoiceOver"))
        .graphCard(empty: selection == nil && graph.neighbours.isEmpty,
                   placeholder: "Click a note to see what it links to. Double-click opens it.") {
            if let selection, let node = graph.nodes.first(where: { $0.id == selection }) {
                NodeCard(node: node, color: GraphPalette.color(for: node, mode: effectiveColorMode),
                         secondary: [.init(title: "Local Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                             openRoute(.localGraph(path: node.path))
                         }],
                         onOpen: { openRoute(.note(path: node.path, anchor: nil)) },
                         onNeighbour: { go(to: $0, from: graph) },
                         onClose: { withAnimation(.snappy) { self.selection = nil } })
                    .id(node.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !graph.neighbours.isEmpty {
                NeighbourClusters(neighbours: graph.neighbours)
            }
        }
    }

    /// A neighbour in this cluster is selected in place; one elsewhere opens
    /// its own cluster (or, outside every cluster, its local graph).
    private func go(to node: GraphNode, from graph: ClusterGraph) {
        if node.cluster == graph.cluster.id, graph.nodes.contains(where: { $0.id == node.id }) {
            withAnimation(.snappy) { selection = node.id }
            focusNode = node.id
        } else if let cluster = node.cluster {
            openRoute(.graphCluster(id: cluster, focus: node.path))
        } else {
            openRoute(.localGraph(path: node.path))
        }
    }

    private func memberList(_ graph: ClusterGraph) -> some View {
        List {
            Section {
                ForEach(centerFirst(visible(graph), graph), id: \.[row: "nodes"]) { node in
                    RouteLink(Route.note(path: node.path, anchor: nil)) {
                        HStack(spacing: 10) {
                            Circle().fill(GraphPalette.color(for: node, mode: effectiveColorMode)).frame(width: 10, height: 10)
                                .overlay {
                                    if node.id == graph.centerID { Circle().stroke(.primary.opacity(0.8), lineWidth: 1.5).padding(-3) }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).lineLimit(2).fontWeight(node.id == graph.centerID ? .semibold : nil)
                                if let kind = node.kindDescription {
                                    Text(kind).chromeFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(node.weight)").chromeFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .accessibilityLabel(Text("\(node.weight) backlinks"))
                        }
                    }
                    .notePreviewMenu(path: node.path, title: node.title)
                }
            } header: {
                Text("Most Linked Notes")
            }
            if !graph.neighbours.isEmpty {
                Section("Linked Clusters") {
                    ForEach(graph.neighbours, id: \.cluster[row: "clusters"]) { item in
                        RouteLink(Route.graphCluster(id: item.cluster.id, focus: nil)) {
                            HStack(spacing: 10) {
                                Circle().fill(GraphPalette.cluster(item.cluster.id)).frame(width: 10, height: 10)
                                Text(item.cluster.label).lineLimit(1)
                                Spacer()
                                Text("\(item.weight) links").chromeFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let session = library.session else { return }
        types = (try? await session.graph.types()) ?? []
        guard let loaded = try? await session.graph.clusterGraph(id: id) else {
            graph = nil
            missing = true
            return
        }
        graph = loaded
        missing = false
        if let focus, let node = loaded.nodes.first(where: { $0.path == focus }) {
            selection = node.id
            focusNode = node.id
        } else if let selection, !loaded.nodes.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}

/// Clusters this one links to most, when nothing is selected: the way
/// across the vault without going back to the overview.
private struct NeighbourClusters: View {
    let neighbours: [(cluster: GraphCluster, weight: Int)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Linked:").chromeFont(.caption).foregroundStyle(.secondary)
                ForEach(neighbours, id: \.cluster.id) { item in
                    RouteLink(Route.graphCluster(id: item.cluster.id, focus: nil)) {
                        HStack(spacing: 4) {
                            Circle().fill(GraphPalette.cluster(item.cluster.id)).frame(width: 7, height: 7)
                            Text(item.cluster.label).lineLimit(1)
                        }
                        .chromeFont(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollClipDisabled()
        .padding(.bottom, 6)
    }
}
