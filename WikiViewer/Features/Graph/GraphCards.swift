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

/// Card container: glass, with a close button.
struct GraphCard<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.fill.tertiary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Selects this linked note"))
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task(id: node.id) {
            neighbours = try? await library.session?.graph.neighbours(of: node.id, limit: 12)
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
