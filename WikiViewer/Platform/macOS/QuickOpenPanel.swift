//
//  QuickOpenPanel.swift
//  WikiViewer
//
//  ⌘O on macOS: a palette over the window that finds a note by title or
//  alias as you type (the quick switcher's query), and opens it with
//  Return, or in a new tab with ⌘Return. With nothing typed it offers the
//  recently read notes.
//

#if os(macOS)
import SwiftUI
import WikiShared
import WikiViewerKit

struct QuickOpenPanel: View {
    /// Opens the chosen note: here, or in a new tab.
    let onOpen: (Route, RouteTarget) -> Void
    let onClose: () -> Void
    @Environment(Library.self) private var library
    @Environment(ReadingHistory.self) private var history
    @State private var query = ""
    @State private var hits: [Item] = []
    /// The query `hits` were found for: until the search for the latest
    /// keystroke is back, they are for an earlier query.
    @State private var hitsQuery = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool
    /// The height of the rows, so the list is no taller than they are.
    @State private var rowsHeight: CGFloat = 0

    static let limit = 30

    struct Item: Identifiable, Hashable {
        var path: String
        var title: String
        /// Folder, or the alias that matched.
        var detail: String
        var id: String { path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Open a note", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { open(in: .automatic) }
            }
            .padding(12)
            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("Recent")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    highlighted = index
                                    open(in: RouteTarget.fromCurrentEvent)
                                } label: {
                                    row(item, highlighted: index == highlighted)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(.vertical, 4)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    }
                    .frame(height: min(rowsHeight, 360))
                    .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("No matching notes")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(items.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        // ⌘Return: a new tab. (Return alone is the field's submit.)
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            open(in: press.modifiers.contains(.option) ? .newWindow : .newTab)
            return .handled
        }
        // Once on screen: focusing in onAppear leaves the list behind it
        // with the keyboard.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            fieldFocused = true
        }
        .onChange(of: fieldFocused) {
            // Clicking elsewhere in the window dismisses the palette.
            if !fieldFocused { onClose() }
        }
        .task(id: query) { await search() }
    }

    private var items: [Item] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return history.recents.prefix(12).map {
                Item(path: $0.path, title: $0.title, detail: VaultPath.folder(of: $0.path))
            }
        }
        return hits
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(highlighted ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // The system's selection color, as menus and Spotlight use: white
        // text on the light accent of dark mode would not read.
        .background(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: .rect(cornerRadius: 7))
        .padding(.horizontal, 6)
        .contentShape(.rect)
    }

    private func open(in target: RouteTarget) {
        let q = trimmedQuery
        guard q.isEmpty || hitsQuery == q else {
            // Return right after a keystroke, before its search is back:
            // open the best match for what was typed, not for the query
            // before it.
            Task {
                guard let found = await find(q), let first = found.first else { return }
                onOpen(.note(path: first.path, anchor: nil), target)
                onClose()
            }
            return
        }
        guard items.indices.contains(highlighted) else { return }
        onOpen(.note(path: items[highlighted].path, anchor: nil), target)
        onClose()
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private func search() async {
        let q = trimmedQuery
        highlighted = 0
        guard !q.isEmpty else {
            hits = []
            hitsQuery = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, let found = await find(q), !Task.isCancelled else { return }
        hits = found
        hitsQuery = q
    }

    private func find(_ q: String) async -> [Item]? {
        guard let session = library.session,
              let found = try? await session.search.quickSwitch(q, limit: Self.limit) else { return nil }
        return found.map { hit in
            let detail: String
            if case .alias(let alias) = hit.match {
                detail = String(localized: "Alias: \(alias)")
            } else {
                detail = VaultPath.folder(of: hit.note.path)
            }
            return Item(path: hit.note.path, title: hit.note.title, detail: detail)
        }
    }
}
#endif
