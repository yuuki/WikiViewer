//
//  NotePreview.swift
//  WikiViewer
//
//  Long-press a note row to peek at the note before opening it.
//

import SwiftUI
import WikiShared
import WikiViewerKit

extension View {
    /// Context menu with a preview of the note at `path` and quick actions.
    func notePreviewMenu(path: String, title: String) -> some View {
        modifier(NotePreviewMenu(path: path, title: title))
    }
}

private struct NotePreviewMenu: ViewModifier {
    let path: String
    let title: String
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute
    @Environment(ReadingHistory.self) private var history

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open", systemImage: "doc.text") {
                openRoute(.note(path: path, anchor: nil))
            }
            let pinned = history.isPinned(path)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                history.togglePin(path: path, title: title)
            }
            Button("Copy Wikilink", systemImage: "curlybraces") {
                Pasteboard.copy("[[\(VaultPath.basename(of: path))]]")
            }
        } preview: {
            NotePreviewCard(path: path, title: title, session: library.session)
        }
    }
}

/// The start of a note, rendered like the note itself.
struct NotePreviewCard: View {
    let path: String
    let title: String
    let session: LibrarySession?
    @State private var blocks: [RenderBlock]?

    /// Enough text to fill the preview; never the whole body.
    static let maxCharacters = 3000
    static let maxBlocks = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            if let blocks {
                ForEach(blocks.prefix(Self.maxBlocks)) { BlockView(block: $0) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 340, height: 420, alignment: .topLeading)
        .clipped()
        .task {
            guard let session, let id = try? await session.notes.noteID(path: path),
                  let body = try? await session.notes.bodyPrefix(id: id, maxCharacters: Self.maxCharacters) else {
                blocks = []
                return
            }
            let links = (try? await session.links.outgoingLinks(of: id)) ?? []
            let rendered = await NoteRenderer.renderInBackground(body: body, noteID: id, links: links, allowEmbeds: false)
            // The title is shown above; skip a leading "# Title".
            var list = rendered.blocks
            if NoteView.startsWithTitleHeading(rendered, title: title) { list.removeFirst() }
            blocks = list
        }
    }
}
