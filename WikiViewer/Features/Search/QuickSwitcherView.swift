//
//  QuickSwitcherView.swift
//  WikiViewer
//
//  Jump to a note by title, alias or path fragment. Index-backed, bounded.
//

import SwiftUI
import WikiViewerKit

struct QuickSwitcherView: View {
    let onSelect: (NoteSummary) -> Void
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List(hits) { hit in
                Button {
                    onSelect(hit.note)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.note.title).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(hit.note.folderPath.isEmpty ? "/" : hit.note.folderPath)
                            if case .alias(let alias) = hit.match { Text("alias: \(alias)") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Open Note")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title or alias")
            .searchFocused($focused)
            .onSubmit(of: .search) {
                if let first = hits.first { onSelect(first.note) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) {
                guard let session = library.session else { return }
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    let result = try await session.search.quickSwitch(query, limit: 40)
                    try Task.checkCancellation()
                    hits = result
                } catch {}
            }
            .onAppear { focused = true }
        }
    }
}
