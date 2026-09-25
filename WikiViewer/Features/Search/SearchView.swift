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
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            // Identity includes the snippet so a row is rebuilt whenever the
            // result for the same note changes between queries.
            ForEach(hits, id: \.self) { hit in
                NavigationLink(value: Route.note(path: hit.note.path, anchor: nil)) {
                    SearchHitRow(hit: hit)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !query.isEmpty, hits.isEmpty, !searching, error == nil {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty {
                ContentUnavailableView("Search Notes", systemImage: "magnifyingglass", description: Text("Full-text search. Terms of 3+ characters search note text; shorter terms match titles, aliases and tags."))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
        .quickSwitcherToolbar()
        .task(id: SearchKey(query: query, session: library.session?.id)) {
            await run()
        }
    }

    struct SearchKey: Hashable {
        var query: String
        var session: String?
    }

    func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let session = library.session else {
            hits = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            searching = true
            defer { searching = false }
            let result = try await session.search.search(q, limit: 100)
            // A superseded query may still finish; never let it overwrite a newer one.
            try Task.checkCancellation()
            hits = result
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
                Text(hit.note.folderPath.isEmpty ? "/" : hit.note.folderPath)
                switch hit.match {
                case .alias(let alias): Text("alias: \(alias)")
                case .tag(let tag): Text("#\(tag)")
                default: EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
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
