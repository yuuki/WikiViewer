//
//  NoteFind.swift
//  WikiViewer
//
//  Find in note (⌘F): the matching blocks of the note on screen, which one
//  is current, and the matches highlighted in the text. The rendered
//  blocks are already in memory; nothing is queried.
//

import SwiftUI
import WikiViewerKit

@MainActor
@Observable
final class NoteFind {
    var isShown = false
    var query = ""
    /// Top-level blocks containing the query, in note order.
    private(set) var matches: [Int] = []
    /// Index into `matches`.
    private(set) var current = 0
    /// Changed to focus the find field.
    private(set) var focusRequest = 0

    var currentBlock: Int? { matches.indices.contains(current) ? matches[current] : nil }

    func show() {
        isShown = true
        focusRequest += 1
    }

    func hide() {
        isShown = false
    }

    func update(in rendered: RenderedNote?) {
        matches = rendered?.blocks(containing: query) ?? []
        current = 0
    }

    func next() {
        guard !matches.isEmpty else { return }
        current = (current + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        current = (current + matches.count - 1) % matches.count
    }
}

extension EnvironmentValues {
    /// Text to highlight in the note's blocks (find in note), or empty.
    @Entry var findHighlight = ""
}

extension AttributedString {
    /// With every occurrence of `query` given a highlight background,
    /// compared as find in note compares blocks.
    func highlightingMatches(of query: String) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return self }
        var result = self
        var start = result.startIndex
        while start < result.endIndex,
              let range = result[start...].range(of: needle, options: RenderedNote.matchOptions) {
            result[range].backgroundColor = Color("Highlight").opacity(0.55)
            start = range.upperBound
        }
        return result
    }
}

/// The find bar above the note.
struct NoteFindBar: View {
    @Bindable var find: NoteFind
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in Note", text: $find.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { find.next() }
                        .onKeyPress(.escape) {
                            find.hide()
                            return .handled
                        }
                    if !find.query.isEmpty {
                        Text(find.matches.isEmpty ? String(localized: "Not found")
                                                  : String(localized: "\(find.current + 1) of \(find.matches.count)"))
                            .chromeFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: .rect(cornerRadius: 7))
                Button("Previous", systemImage: "chevron.up") { find.previous() }
                    .labelStyle(.iconOnly)
                    .disabled(find.matches.isEmpty)
                    .help("Find Previous (⇧⌘G)")
                Button("Next", systemImage: "chevron.down") { find.next() }
                    .labelStyle(.iconOnly)
                    .disabled(find.matches.isEmpty)
                    .help("Find Next (⌘G)")
                Button("Done") { find.hide() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}
