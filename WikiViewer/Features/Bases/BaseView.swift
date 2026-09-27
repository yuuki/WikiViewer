//
//  BaseView.swift
//  WikiViewer
//
//  One Obsidian Bases file. The indexer already filtered, sorted and grouped
//  the notes of every view; this screen pages through one view at a time.
//  Views are chosen from the title menu, like Obsidian's view switcher.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct BaseView: View {
    let path: String
    @Environment(Library.self) private var library
    @State private var model = BaseModel()

    var body: some View {
        content
            .navigationTitle(model.info?.name ?? VaultPath.basename(of: path))
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(subtitle)
            .toolbarTitleMenu {
                if let views = model.info?.document.views, views.count > 1 {
                    Picker("View", selection: Binding(get: { model.viewIndex }, set: { select($0) })) {
                        ForEach(views.indices, id: \.self) { index in
                            Label(views[index].name, systemImage: Self.symbol(for: views[index].type)).tag(index)
                        }
                    }
                }
            }
            .task(id: library.session?.id) {
                guard let session = library.session else { return }
                await model.load(path: path, session: session)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView("Not in Snapshot", systemImage: "tablecells", description: Text("\(path) is not in the current snapshot."))
        case .failed(let message):
            ContentUnavailableView("Couldn't Load Base", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if let error = model.info?.document.error {
                Section {
                    Label {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            if let view = model.view {
                if view.grouped {
                    ForEach(model.sections, id: \.group.key) { section in
                        Section {
                            rows(section.rows, view: view)
                        } header: {
                            HStack {
                                Text(section.group.label ?? String(localized: "None"))
                                Spacer()
                                Text(section.group.rowCount, format: .number).monospacedDigit()
                            }
                        }
                    }
                } else {
                    rows(model.rows[...], view: view)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.rows.isEmpty, !model.hasMore, model.view != nil {
                ContentUnavailableView("No Notes", systemImage: "tablecells")
            }
        }
    }

    private func rows(_ rows: ArraySlice<BaseRow>, view: BaseDocument.View) -> some View {
        ForEach(rows) { row in
            NavigationLink(value: Route.note(path: row.note.path, anchor: nil)) {
                BaseRowView(row: row, columns: view.columns.filter { !$0.isFileName })
            }
            .notePreviewMenu(path: row.note.path, title: row.note.title)
            .onAppear {
                if row.id == model.rows.last?.id, let session = library.session {
                    Task { await model.loadMore(session: session) }
                }
            }
        }
    }

    private var subtitle: Text {
        guard let view = model.view else { return Text(verbatim: "") }
        let count = Text("^[\(view.rowCount) note](inflect: true)")
        guard (model.info?.document.views.count ?? 0) > 1 else { return count }
        return Text("\(view.name) · \(count)")
    }

    private func select(_ index: Int) {
        guard index != model.viewIndex, let session = library.session else { return }
        Task { await model.select(view: index, session: session) }
    }

    static func symbol(for type: String) -> String {
        switch type {
        case "list": "list.bullet"
        case "cards": "square.grid.2x2"
        case "map": "map"
        default: "tablecells"
        }
    }
}

/// A note of a base: its file name (what Obsidian shows for `file.name`)
/// and the view's other columns as label–value pairs.
struct BaseRowView: View {
    let row: BaseRow
    let columns: [BaseDocument.Column]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name).lineLimit(2)
            if let details {
                details
                    .font(.caption)
                    .lineLimit(3)
            }
        }
    }

    private var details: Text? {
        let parts = columns.compactMap { column -> Text? in
            guard let cell = row.cells[column.id], !cell.isEmpty else { return nil }
            // A no-break space keeps each label on the line of its value.
            return Text("\(Text(column.label).foregroundStyle(.secondary))\u{00A0}\(cell.displayText)")
        }
        guard var text = parts.first else { return nil }
        for part in parts.dropFirst() {
            text = Text("\(text)\(Text(verbatim: "  ·  ").foregroundStyle(.tertiary))\(part)")
        }
        return text
    }
}

@Observable
final class BaseModel {
    enum Phase: Equatable {
        case loading, missing, loaded
        case failed(String)
    }

    struct Section {
        var group: BaseGroup
        var rows: ArraySlice<BaseRow>
    }

    private(set) var phase: Phase = .loading
    private(set) var info: BaseInfo?
    private(set) var viewIndex = 0
    private(set) var rows: [BaseRow] = []
    private(set) var hasMore = false
    private var groups: [Data: BaseGroup] = [:]
    private var sessionID: String?
    private var loadingMore = false

    static let pageSize = 100

    var view: BaseDocument.View? {
        guard let views = info?.document.views, views.indices.contains(viewIndex) else { return nil }
        return views[viewIndex]
    }

    /// Loaded rows split by group, in order (rows arrive in group order).
    var sections: [Section] {
        var out: [Section] = []
        var start = rows.startIndex
        while start < rows.endIndex {
            let key = rows[start].groupKey
            var end = start
            while end < rows.endIndex, rows[end].groupKey == key { end += 1 }
            out.append(Section(group: groups[key] ?? BaseGroup(key: key, label: nil, rowCount: end - start), rows: rows[start..<end]))
            start = end
        }
        return out
    }

    func load(path: String, session: LibrarySession) async {
        do {
            guard let info = try await session.bases.base(path: path) else {
                phase = .missing
                return
            }
            self.info = info
            sessionID = session.id
            // Keep the chosen view across generations when it still exists.
            let remembered = BaseViewStore.view(for: path)
            viewIndex = info.document.views.firstIndex { $0.name == remembered } ?? 0
            try await loadView(session: session)
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func select(view index: Int, session: LibrarySession) async {
        guard let info, session.id == sessionID else { return }
        viewIndex = index
        BaseViewStore.setView(info.document.views[index].name, for: info.path)
        do {
            try await loadView(session: session)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadView(session: LibrarySession) async throws {
        guard let info, let view else {
            rows = []
            hasMore = false
            return
        }
        let loadedGroups = view.grouped ? try await session.bases.groups(baseID: info.assetID, view: viewIndex) : []
        let page = try await session.bases.rows(baseID: info.assetID, view: viewIndex, limit: Self.pageSize)
        groups = Dictionary(loadedGroups.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        rows = page.items
        hasMore = page.hasMore
    }

    func loadMore(session: LibrarySession) async {
        // Never mix pages from two generations or two views.
        guard hasMore, !loadingMore, session.id == sessionID, let info, let last = rows.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let view = viewIndex
        if let page = try? await session.bases.rows(baseID: info.assetID, view: view, after: BaseCursor(after: last), limit: Self.pageSize),
           view == viewIndex {
            rows.append(contentsOf: page.items)
            hasMore = page.hasMore
        }
    }
}

/// The view last chosen in each base.
enum BaseViewStore {
    static let key = "WikiViewer.baseView"
    static let limit = 200

    static func view(for path: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[path]
    }

    static func setView(_ name: String, for path: String) {
        var views = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        views[path] = name
        if views.count > limit { views.removeValue(forKey: views.keys.first { $0 != path }!) }
        UserDefaults.standard.set(views, forKey: key)
    }
}
