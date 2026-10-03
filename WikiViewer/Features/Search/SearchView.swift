//
//  SearchView.swift
//  WikiViewer
//
//  Full-text search (FTS5 trigram) with snippets. Queries are debounced and
//  the previous query is cancelled when the text changes.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
    @State private var query = ""
    /// Title and alias matches, shown first (what the quick switcher gave).
    @State private var titleHits: [SearchHit] = []
    /// Everything else the full-text search found.
    @State private var hits: [SearchHit] = []
    /// Whether every title match is shown, not only the first `titlePreview`.
    @State private var showsAllTitles = false
    @State private var searching = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool
    @State private var handledFocusRequest = 0

    /// Title and alias matches fetched per query.
    static let titleLimit = 200
    /// Title matches shown before "Show All", so text matches stay in view.
    static let titlePreview = 6

    var body: some View {
        RouteList {
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            if searchesTitlesOnly {
                // Stays with the results: a two-character Japanese word that
                // is only in note text would otherwise look like a miss.
                Label("Terms under 3 characters only match titles, aliases and tags. Add a longer term to search note text.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            if !titleHits.isEmpty {
                Section("Titles") {
                    ForEach(showsAllTitles ? titleHits : Array(titleHits.prefix(Self.titlePreview))) { hit in
                        RouteLink(Route.note(path: hit.note.path, anchor: nil)) {
                            SearchHitRow(hit: hit)
                        }
                        .notePreviewMenu(path: hit.note.path, title: hit.note.title)
                    }
                    if !showsAllTitles, titleHits.count > Self.titlePreview {
                        Button {
                            showsAllTitles = true
                        } label: {
                            Text(titleHits.count < Self.titleLimit ? "Show All \(titleHits.count) Titles" : "Show \(titleHits.count)+ Titles")
                        }
                    }
                }
            }
            if !hits.isEmpty {
                Section(searchesTitlesOnly ? "Tags" : "In Notes") {
                    // Identity includes the snippet so a row is rebuilt whenever the
                    // result for the same note changes between queries.
                    ForEach(hits, id: \.self) { hit in
                        RouteLink(Route.note(path: hit.note.path, anchor: matchAnchor(for: hit))) {
                            SearchHitRow(hit: hit)
                        }
                        .notePreviewMenu(path: hit.note.path, title: hit.note.title)
                    }
                    .listRowSection("matches")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !query.isEmpty, hits.isEmpty, titleHits.isEmpty, !searching, error == nil {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty {
                // The 3-character rule is explained next to the results it affects.
                ContentUnavailableView("Search Notes", systemImage: "magnifyingglass", description: Text("Find notes by title, alias or text."))
            }
        }
        .navigationTitle("Search")
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Titles and text")
        .searchFocused($fieldFocused)
        .onSubmit(of: .search, openBestMatch)
        #else
        .inlineSearchField(text: $query, prompt: "Titles and text", focused: $fieldFocused, onSubmit: openBestMatch)
        #endif
        .onAppear(perform: focusIfRequested)
        .onChange(of: app.searchFocusRequest) { focusIfRequested() }
        .task(id: SearchKey(query: query, session: library.session?.id)) {
            await run()
        }
    }

    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openRoute) private var openRoute

    /// Return opens the best title match, like the quick switcher did.
    private func openBestMatch() {
        if let first = titleHits.first ?? hits.first {
            openRoute(.note(path: first.note.path, anchor: nil))
        }
    }

    /// Opens a note-text match at the block containing the query.
    private func matchAnchor(for hit: SearchHit) -> NoteAnchor? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard hit.snippet != nil, !q.isEmpty else { return nil }
        return NoteAnchor(text: q)
    }

    private var searchesTitlesOnly: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && !TrigramSearchEngine.searchesNoteText(query)
    }

    func focusIfRequested() {
        let request = app.searchFocusRequest
        guard request.id != handledFocusRequest else { return }
        handledFocusRequest = request.id
        if request.resetNavigation {
            navigation.path.removeAll()
        } else if !navigation.path.isEmpty {
            return
        }
        // The field only takes focus once it is on screen.
        Task { fieldFocused = true }
    }

    struct SearchKey: Hashable {
        var query: String
        var session: String?
    }

    func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let session = library.session else {
            hits = []
            titleHits = []
            return
        }
        // Counts as searching during the debounce too, so "No Results" does
        // not flash while the user is still typing.
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(200))
            async let titles = session.search.quickSwitch(q, limit: Self.titleLimit)
            // Title matches come first here too; leave room for 100 text matches.
            async let full = session.search.search(q, limit: Self.titleLimit + 100)
            let (titleResult, fullResult) = try await (titles, full)
            // A superseded query may still finish; never let it overwrite a newer one.
            try Task.checkCancellation()
            let titleIDs = Set(titleResult.map(\.id))
            if titleResult.map(\.id) != titleHits.map(\.id) { showsAllTitles = false }
            titleHits = titleResult
            hits = fullResult.filter { !titleIDs.contains($0.id) }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.note.title).font(.body.weight(.medium))
            if let snippet = hit.snippet {
                Text(Self.highlighted(snippet))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                if !hit.note.folderPath.isEmpty {
                    Text("\(Image(systemName: "folder")) \(hit.note.folderPath)")
                }
                switch hit.match {
                case .alias(let alias): Text("alias: \(alias)")
                case .tag(let tag): Text("#\(tag)")
                default: EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Converts FTS5 snippet markers into bold + tinted runs.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var current = ""
        var inMatch = false
        func flush() {
            guard !current.isEmpty else { return }
            var run = AttributedString(current.replacingOccurrences(of: "\n", with: " "))
            if inMatch {
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .primary
            }
            out.append(run)
            current = ""
        }
        for c in snippet {
            if c == SearchHit.highlightStart { flush(); inMatch = true }
            else if c == SearchHit.highlightEnd { flush(); inMatch = false }
            else { current.append(c) }
        }
        flush()
        return out
    }
}
