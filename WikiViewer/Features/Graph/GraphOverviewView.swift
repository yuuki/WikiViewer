//
//  GraphOverviewView.swift
//  WikiViewer
//
//  The Graph tab: the vault's clusters as a map of bubbles (or a list), and
//  a search to jump to any note's place in the graph. A tap selects a
//  cluster and says what is in it; a second tap, or the card's button, goes
//  into it.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct GraphOverviewView: View {
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute
    @State private var overview: GraphOverview?
    @State private var failure: String?
    @State private var selection: Int64?
    @AppStorage("WikiViewer.graph.overviewAsList") private var showsList = false
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        content
            .navigationTitle("Graph")
            .navigationSubtitle(subtitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if overview?.clusters.isEmpty == false {
                    ToolbarItem(placement: .primaryAction) {
                        Button(showsList ? "Map" : "List", systemImage: showsList ? "circle.hexagongrid" : "list.bullet") {
                            showsList.toggle()
                        }
                    }
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Find a note in the graph"))
            #else
            .searchable(text: $query, placement: .toolbar, prompt: Text("Find a note in the graph"))
            #endif
            .task(id: library.session?.id) { await load() }
            .task(id: query) { await search() }
    }

    private var subtitle: Text {
        guard let overview, overview.clusterCount > 0 else { return Text(verbatim: "") }
        return Text("\(overview.clusterCount) clusters · \(overview.nodeCount) notes")
    }

    @ViewBuilder
    private var content: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else if let overview {
            if overview.clusters.isEmpty {
                ContentUnavailableView("No Graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("This snapshot has no clusters of linked notes. The Mac's indexer builds them from notes that link to each other."))
            } else if showsList {
                ClusterListView()
            } else {
                map(overview)
            }
        } else if let failure {
            ContentUnavailableView("Couldn't Load Graph", systemImage: "exclamationmark.triangle", description: Text(failure))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func map(_ overview: GraphOverview) -> some View {
        GraphCanvas(scene: Self.scene(overview), selection: selection, fitKey: overview.clusters.map(\.id), labelBudget: 60,
                    onDoubleClick: { openRoute(.graphCluster(id: $0, focus: nil)) }) { id in
            if let id, id == selection {
                openRoute(.graphCluster(id: id, focus: nil))
            } else {
                withAnimation(.snappy) { selection = id }
            }
        }
        .accessibilityLabel(Text("Map of \(overview.clusters.count) clusters"))
        .accessibilityHint(Text("Switch to the list to browse clusters with VoiceOver"))
        .graphCard(empty: selection == nil,
                   placeholder: "Click a cluster to see what is in it. Double-click opens it.") {
            if let selection, let cluster = overview.clusters.first(where: { $0.id == selection }) {
                ClusterCard(cluster: cluster) {
                    openRoute(.graphCluster(id: cluster.id, focus: nil))
                } onClose: {
                    withAnimation(.snappy) { self.selection = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    static func scene(_ overview: GraphOverview) -> GraphScene {
        let nodes = overview.clusters.map { c in
            GraphScene.Node(id: c.id, position: CGPoint(x: c.x, y: -c.y), radius: c.radius, color: GraphPalette.cluster(c.id),
                            label: c.label, sublabel: String(localized: "\(c.size) notes"), priority: Double(c.size), style: .bubble)
        }
        let strongest = Double(overview.links.map(\.weight).max() ?? 1)
        let edges = overview.links.map { l in
            GraphScene.Edge(a: l.a, b: l.b, width: 1.2 + 4 * log(1 + Double(l.weight)) / log(1 + strongest), onlyWhenSelected: !l.skeleton)
        }
        return GraphScene(nodes: nodes, edges: edges)
    }

    private var searchResults: some View {
        List(hits) { hit in
            Button {
                Task { await open(hit.note) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.note.title).foregroundStyle(.primary)
                    Text(hit.note.folderPath.isEmpty ? "/" : hit.note.folderPath).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if hits.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func load() async {
        guard let session = library.session else { return }
        do {
            overview = try await session.graph.overview()
            failure = nil
            if let selection, overview?.clusters.contains(where: { $0.id == selection }) != true { self.selection = nil }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let session = library.session else {
            hits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        hits = (try? await session.search.quickSwitch(q, limit: 30)) ?? []
    }

    /// A note in a cluster opens there; any other note opens its local graph.
    private func open(_ note: NoteSummary) async {
        let node = try? await library.session?.graph.node(id: note.id)
        if let cluster = node?.cluster {
            openRoute(.graphCluster(id: cluster, focus: note.path))
        } else {
            openRoute(.localGraph(path: note.path))
        }
    }
}

/// Every cluster, largest first, with its best-known notes. Also the
/// Graph section's list on macOS.
struct ClusterListView: View {
    @Environment(Library.self) private var library
    @State private var clusters: [GraphCluster] = []
    @State private var hasMore = false

    var body: some View {
        RouteList {
            ForEach(clusters) { cluster in
                RouteLink(Route.graphCluster(id: cluster.id, focus: nil)) {
                    ClusterRow(cluster: cluster)
                }
            }
            if hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
            }
        }
        .task(id: library.session?.id) {
            clusters = []
            await loadMore()
        }
    }

    private func loadMore() async {
        guard let session = library.session,
              let page = try? await session.graph.clusters(after: clusters.last, limit: 100) else { return }
        clusters += page.items
        hasMore = page.hasMore
    }
}

private struct ClusterRow: View {
    let cluster: GraphCluster
    @Environment(Library.self) private var library
    @State private var members: [GraphNode]?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(GraphPalette.cluster(cluster.id)).frame(width: 12, height: 12).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cluster.label).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(cluster.size.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let members {
                    Text(members.filter { $0.title != cluster.label }.prefix(3).map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .task(id: cluster.id) {
            members = try? await library.session?.graph.members(of: cluster.id, limit: 4)
        }
    }
}
