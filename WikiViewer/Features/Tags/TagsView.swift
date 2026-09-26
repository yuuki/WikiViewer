//
//  TagsView.swift
//  WikiViewer
//
//  Tags as a hierarchy (`project` → `project/alpha`), or a flat list of
//  matches while filtering.
//

import SwiftUI
import WikiViewerKit

struct TagsView: View {
    @Environment(Library.self) private var library
    @State private var filter = ""
    /// Top-level tags, shown while not filtering.
    @State private var roots: [TagNode] = []
    /// Tags matching the filter, flat.
    @State private var tags: [TagSummary] = []
    @State private var hasMore = false
    @State private var order: TagRepository.Order = .count
    @State private var loading = false
    @State private var loaded = false

    private var filtering: Bool { !normalizedFilter.isEmpty }
    private var normalizedFilter: String {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.hasPrefix("#") ? String(f.dropFirst()) : f
    }

    var body: some View {
        List {
            if filtering {
                ForEach(tags) { tag in
                    NavigationLink(value: Route.tag(name: tag.name)) {
                        TagRow(name: "#" + tag.name, count: tag.noteCount, hasChildren: false)
                    }
                    .onAppear {
                        if tag.id == tags.last?.id { Task { await loadFiltered(reset: false) } }
                    }
                }
            } else {
                ForEach(TagNode.sorted(roots, by: order)) { node in
                    NavigationLink(value: Route.tag(name: node.name)) {
                        TagRow(name: "#" + node.name, count: node.noteCount, hasChildren: node.hasChildren)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loaded, !loading {
                if filtering, tags.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else if !filtering, roots.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "number", description: Text("Notes in this snapshot have no tags."))
                }
            }
        }
        .navigationTitle("Tags")
        .searchable(text: $filter, prompt: "Filter tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort Tags", selection: $order) {
                        Text("Most Used").tag(TagRepository.Order.count)
                        Text("Name").tag(TagRepository.Order.name)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort Tags", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: Key(filter: normalizedFilter, order: order, session: library.session?.id)) {
            if filtering {
                await loadFiltered(reset: true)
            } else {
                await loadRoots()
            }
            loaded = true
        }
    }

    struct Key: Hashable {
        var filter: String
        var order: TagRepository.Order
        var session: String?
    }

    func loadRoots() async {
        guard let session = library.session else { return }
        loading = true
        defer { loading = false }
        roots = (try? await session.tags.childTags()) ?? []
    }

    func loadFiltered(reset: Bool) async {
        guard let session = library.session else { return }
        if !reset && (!hasMore || loading) { return }
        loading = true
        defer { loading = false }
        let offset = reset ? 0 : tags.count
        guard let page = try? await session.tags.tags(prefix: normalizedFilter, order: order, limit: 200, offset: offset) else { return }
        tags = reset ? page.items : tags + page.items
        hasMore = page.hasMore
    }
}

extension TagNode {
    static func sorted(_ nodes: [TagNode], by order: TagRepository.Order) -> [TagNode] {
        guard order == .count else { return nodes }
        return nodes.sorted { $0.noteCount != $1.noteCount ? $0.noteCount > $1.noteCount : $0.component.localizedStandardCompare($1.component) == .orderedAscending }
    }
}

struct TagRow: View {
    let name: String
    let count: Int
    let hasChildren: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if hasChildren {
                    Text("Has nested tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("^[\(count) note](inflect: true)"))
            }
        }
    }
}

struct TagNotesView: View {
    let name: String
    @Environment(Library.self) private var library
    @State private var children: [TagNode] = []
    @State private var notes: [NoteSummary] = []
    @State private var hasMore = false
    @AppStorage("WikiViewer.includeNestedTags") private var includeNested = true
    @State private var loading = false
    @State private var loaded = false

    var body: some View {
        List {
            if !children.isEmpty {
                Section("Nested Tags") {
                    ForEach(children) { node in
                        NavigationLink(value: Route.tag(name: node.name)) {
                            TagRow(name: "#" + node.component, count: node.noteCount, hasChildren: node.hasChildren)
                        }
                    }
                }
            }
            Section {
                ForEach(notes) { note in
                    NavigationLink(value: Route.note(path: note.path, anchor: nil)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                            if !note.folderPath.isEmpty {
                                Text(note.folderPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .notePreviewMenu(path: note.path, title: note.title)
                    .onAppear {
                        if note.id == notes.last?.id { Task { await load(reset: false) } }
                    }
                }
            } header: {
                if !children.isEmpty, !notes.isEmpty { Text("Notes") }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loaded, notes.isEmpty, children.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "number", description: Text("#\(name) is not used in this snapshot."))
            }
        }
        .navigationTitle("#" + name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Toggle("Include Nested Tags", systemImage: "number", isOn: $includeNested)
            }
        }
        .task(id: "\(library.session?.id ?? "")|\(includeNested)") {
            await load(reset: true)
            loaded = true
        }
    }

    func load(reset: Bool) async {
        guard let session = library.session else { return }
        if !reset && (loading || !hasMore) { return }
        loading = true
        defer { loading = false }
        if reset { children = (try? await session.tags.childTags(of: name)) ?? [] }
        guard let page = try? await session.tags.notes(underTag: name, includeNested: includeNested, before: reset ? nil : notes.last?.id, limit: 200) else { return }
        notes = reset ? page.items : notes + page.items
        hasMore = page.hasMore
    }
}
