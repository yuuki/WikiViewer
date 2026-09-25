//
//  TagsView.swift
//  WikiViewer
//

import SwiftUI
import WikiViewerKit

struct TagsView: View {
    @Environment(Library.self) private var library
    @State private var filter = ""
    @State private var tags: [TagSummary] = []
    @State private var hasMore = false
    @State private var order: TagRepository.Order = .count
    @State private var loading = false

    var body: some View {
        List {
            ForEach(tags) { tag in
                NavigationLink(value: Route.tag(name: tag.name)) {
                    HStack {
                        Text("#" + tag.name)
                        Spacer()
                        Text("\(tag.noteCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if tag.id == tags.last?.id { Task { await load(reset: false) } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Tags")
        .searchable(text: $filter, prompt: "Filter tags")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Picker("Sort", selection: $order) {
                    Text("By count").tag(TagRepository.Order.count)
                    Text("By name").tag(TagRepository.Order.name)
                }
            }
        }
        .quickSwitcherToolbar()
        .task(id: Key(filter: filter, order: order, session: library.session?.id)) {
            await load(reset: true)
        }
    }

    struct Key: Hashable {
        var filter: String
        var order: TagRepository.Order
        var session: String?
    }

    func load(reset: Bool) async {
        guard let session = library.session else { return }
        if !reset && (!hasMore || loading) { return }
        loading = true
        defer { loading = false }
        let offset = reset ? 0 : tags.count
        guard let page = try? await session.tags.tags(prefix: filter.hasPrefix("#") ? String(filter.dropFirst()) : filter, order: order, limit: 200, offset: offset) else { return }
        tags = reset ? page.items : tags + page.items
        hasMore = page.hasMore
    }
}

struct TagNotesView: View {
    let name: String
    @Environment(Library.self) private var library
    @State private var notes: [NoteSummary] = []
    @State private var hasMore = false
    @State private var tag: TagSummary?
    @State private var includeNested = true
    @State private var loading = false

    var body: some View {
        List {
            Toggle("Include nested tags", isOn: $includeNested)
                .font(.footnote)
            ForEach(notes) { note in
                NavigationLink(value: Route.note(path: note.path, anchor: nil)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                        Text(note.folderPath.isEmpty ? "/" : note.folderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if note.id == notes.last?.id { Task { await load(reset: false) } }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if tag == nil, notes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "number", description: Text("#\(name) is not used in this snapshot."))
            }
        }
        .navigationTitle("#" + name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(library.session?.id ?? "")|\(includeNested)") {
            await load(reset: true)
        }
    }

    func load(reset: Bool) async {
        guard let session = library.session else { return }
        if !reset && loading { return }
        loading = true
        defer { loading = false }
        if reset { tag = try? await session.tags.tag(named: name) }
        guard let tag, reset || hasMore else { return }
        guard let page = try? await session.tags.notes(taggedWith: tag, includeNested: includeNested, before: reset ? nil : notes.last?.id, limit: 200) else { return }
        notes = reset ? page.items : notes + page.items
        hasMore = page.hasMore
    }
}
