//
//  GraphCards.swift
//  WikiViewer
//
//  The card at the bottom of a graph screen that describes what is selected
//  and offers the next step: open the note, walk to a neighbour, go into a
//  cluster. On a phone this replaces wiki-lens's hover tooltips and side
//  panel, and keeps the graph above it usable.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// Where a graph shows the card of what is selected.
enum GraphCardPlacement {
    /// Over the bottom of the graph (iOS).
    case overlay
    /// In the window's inspector (macOS), as Backlinks and Outline are
    /// for a note.
    case inspector
}

extension EnvironmentValues {
    @Entry var graphCardPlacement = GraphCardPlacement.overlay
}

extension View {
    /// The card of what is selected in the graph: over its bottom edge on
    /// iOS, in the inspector (⌥⌘I) on macOS, where `placeholder` stands in
    /// while the card is `empty`.
    func graphCard<Card: View>(empty: Bool, placeholder: LocalizedStringKey, @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(GraphCardModifier(empty: empty, placeholder: placeholder, card: card))
    }
}

private struct GraphCardModifier<Card: View>: ViewModifier {
    let empty: Bool
    let placeholder: LocalizedStringKey
    let card: () -> Card
    #if os(macOS)
    @Environment(AppModel.self) private var app
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .inspector(isPresented: Bindable(app).showsInspector) {
                Group {
                    if empty {
                        ContentUnavailableView("No Selection", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text(placeholder))
                    } else {
                        ScrollView {
                            card().environment(\.graphCardPlacement, .inspector)
                        }
                    }
                }
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.showsInspector.toggle()
                    } label: {
                        Label(app.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("What is selected in the graph (⌥⌘I)")
                }
            }
        #else
        content.safeAreaInset(edge: .bottom) { card() }
        #endif
    }
}

/// Card container: glass over the graph, with a close button; plain in
/// the inspector.
struct GraphCard<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.graphCardPlacement) private var placement

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .padding(4)
        }
        switch placement {
        case .inspector:
            card
        case .overlay:
            card
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 12)
                // Apart from the tab bar, so the two glass shapes do not merge.
                .padding(.bottom, 12)
        }
    }
}

/// A selected note: what it is, how linked, and its strongest neighbours.
struct NodeCard: View {
    let node: GraphNode
    let color: Color
    /// Actions besides opening the note, shown as buttons.
    var secondary: [CardAction] = []
    let onOpen: () -> Void
    let onNeighbour: (GraphNode) -> Void
    let onClose: () -> Void
    @Environment(Library.self) private var library
    @Environment(\.graphCardPlacement) private var placement
    @State private var neighbours: [GraphNeighbour]?

    struct CardAction: Identifiable {
        var title: LocalizedStringKey
        var systemImage: String
        var action: () -> Void
        var id: String { systemImage }
    }

    var body: some View {
        GraphCard(onClose: onClose) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title).font(.headline).lineLimit(2)
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 28)
            }
            HStack {
                Button("Open Note", systemImage: "doc.text", action: onOpen)
                    .buttonStyle(.glassProminent)
                ForEach(secondary) { item in
                    Button(item.title, systemImage: item.systemImage, action: item.action)
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.small)
            if let neighbours, !neighbours.isEmpty {
                switch placement {
                case .overlay:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { chips(neighbours) }
                    }
                    .scrollClipDisabled()
                case .inspector:
                    // A narrow column: one linked note per line.
                    VStack(alignment: .leading, spacing: 4) { chips(neighbours) }
                }
            }
        }
        .task(id: node.id) {
            neighbours = try? await library.session?.graph.neighbours(of: node.id, limit: 12)
        }
    }

    private func chips(_ neighbours: [GraphNeighbour]) -> some View {
        ForEach(neighbours) { n in
            Button {
                onNeighbour(n.node)
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(GraphPalette.cluster(n.node.cluster)).frame(width: 7, height: 7)
                    Text(n.node.title).lineLimit(1).frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    if n.node.cluster != node.cluster, n.node.cluster != nil {
                        Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: Capsule())
                // The chip is drawn compact; the hit area is not (a
                // finger's on a phone).
                .frame(minHeight: placement == .overlay ? 44 : 0)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Selects this linked note"))
        }
    }

    private var details: String {
        var parts: [String] = []
        if let kind = node.kindDescription { parts.append(kind) }
        parts.append(String(localized: "\(node.weight) backlinks"))
        return parts.joined(separator: " · ")
    }
}

/// A selected cluster on the overview.
struct ClusterCard: View {
    let cluster: GraphCluster
    let onOpen: () -> Void
    let onClose: () -> Void
    @Environment(Library.self) private var library
    @State private var members: [GraphNode]?

    var body: some View {
        GraphCard(onClose: onClose) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(GraphPalette.cluster(cluster.id)).frame(width: 12, height: 12).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.label).font(.headline).lineLimit(2)
                    Text("\(cluster.size) notes").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.trailing, 28)
            }
            if let members {
                Text(members.map(\.title).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button("Open Cluster", systemImage: "arrow.right.circle", action: onOpen)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
        .task(id: cluster.id) {
            members = try? await library.session?.graph.members(of: cluster.id, limit: 5)
        }
    }
}

/// Colour-by and type filter, shared by the cluster view and the local graph.
struct GraphDisplayMenu: View {
    let types: [GraphType]
    @AppStorage(GraphPreferences.colorModeKey) private var colorMode: GraphColorMode = .type
    @AppStorage(GraphPreferences.hiddenTypesKey) private var hiddenTypes = ""

    var body: some View {
        Menu {
            Picker("Color By", selection: $colorMode) {
                ForEach(GraphColorMode.allCases) { Text($0.title).tag($0) }
            }
            if !types.isEmpty {
                Section("Show Types") {
                    ForEach(types) { type in
                        Toggle(isOn: binding(for: type.name)) {
                            Text(type.name)
                            Text("\(type.count) notes")
                        }
                    }
                }
                if !GraphPreferences.decode(hiddenTypes).isEmpty {
                    Button("Show All Types", systemImage: "eye") { hiddenTypes = "" }
                }
            }
        } label: {
            Label("Display", systemImage: "slider.horizontal.3")
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding {
            !GraphPreferences.decode(hiddenTypes).contains(name)
        } set: { visible in
            var hidden = GraphPreferences.decode(hiddenTypes)
            if visible {
                hidden.remove(name)
            } else {
                // Keep at least one type visible.
                guard types.filter({ !hidden.contains($0.name) }).count > 1 else { return }
                hidden.insert(name)
            }
            hiddenTypes = GraphPreferences.encode(hidden)
        }
    }
}
