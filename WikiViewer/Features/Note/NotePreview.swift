//
//  NotePreview.swift
//  WikiViewer
//
//  Long-press a note row to peek at the note before opening it. On macOS,
//  where a context menu has no preview, hold ⌘ over the row instead (as
//  Obsidian's page preview does).
//

import SwiftUI
import WikiShared
import WikiViewerKit
#if os(macOS)
import AppKit
#endif

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
    @Environment(\.openURL) private var openURL
    @AppStorage(ObsidianLink.vaultNameKey) private var obsidianVault = ""

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open", systemImage: "doc.text") {
                openRoute(.note(path: path, anchor: nil))
            }
            #if os(macOS)
            Button("Open in New Tab", systemImage: "plus.square.on.square") {
                openRoute(.note(path: path, anchor: nil), in: .newTab)
            }
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openRoute(.note(path: path, anchor: nil), in: .newWindow)
            }
            #endif
            let pinned = history.isPinned(path)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                history.togglePin(path: path, title: title)
            }
            if let obsidian = ObsidianLink.url(vault: obsidianVault, notePath: path) {
                Button("Edit in Obsidian", systemImage: "square.and.pencil") { openURL(obsidian) }
            }
            Button("Copy Wikilink", systemImage: "curlybraces") {
                Pasteboard.copy("[[\(VaultPath.basename(of: path))]]")
            }
        } preview: {
            NotePreviewCard(path: path, title: title, session: library.session)
        }
        #if os(macOS)
        .modifier(CommandHoverPreview(path: path, title: title))
        #endif
    }
}

#if os(macOS)
/// A preview of the note in a popover when ⌘ is held with the pointer over
/// the view, until the pointer leaves: plain hovering, as when moving across
/// a list to click, shows nothing.
struct CommandHoverPreview: ViewModifier {
    let path: String
    let title: String
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute
    @State private var hovering = false
    @State private var showing = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside { watchCommandKey() } else { stopWatching() }
                update()
            }
            .popover(isPresented: Binding { showing } set: { if !$0 { dismissed() } }, arrowEdge: .trailing) {
                NotePreviewCard(path: path, title: title, session: library.session)
            }
            .onDisappear(perform: stopWatching)
    }

    /// The popover takes a click outside it only to close itself: a click
    /// on the view opens the note (in a new tab for a ⌘-click).
    private func dismissed() {
        showing = false
        if NSApp.currentEvent?.type == .leftMouseDown, hovering {
            openRoute(.note(path: path, anchor: nil), in: RouteTarget.fromCurrentEvent)
        }
    }

    private func update() {
        if !hovering {
            showing = false
        } else if NSEvent.modifierFlags.contains(.command) {
            showing = true
        }
    }

    /// ⌘ pressed or released while the pointer rests on the view.
    private func watchCommandKey() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            update()
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

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
