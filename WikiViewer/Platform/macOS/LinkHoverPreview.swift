//
//  LinkHoverPreview.swift
//  WikiViewer
//
//  ⌘ over a link in a note's text shows the linked note in a popover, as
//  Obsidian's page preview does. SwiftUI does not say which link of a Text
//  is under the pointer, so the text is built with each link run marked
//  (`Text(math:markingLinks:)`), a TextRenderer records where those runs
//  were laid out, and the pointer is looked up among them.
//

#if os(macOS)
import AppKit
import SwiftUI
import WikiViewerKit

/// Where the marked link runs of one Text were drawn, in its own
/// coordinates. Written while drawing, read on hover.
final class LinkRunLayout: @unchecked Sendable {
    var runs: [(url: URL, rect: CGRect)] = []

    func link(at point: CGPoint) -> (url: URL, rect: CGRect)? {
        runs.first { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }
    }
}

/// Draws the text unchanged and records its marked link runs.
struct LinkRunRecorder: TextRenderer {
    let layout: LinkRunLayout

    func draw(layout textLayout: Text.Layout, in context: inout GraphicsContext) {
        var runs: [(url: URL, rect: CGRect)] = []
        for line in textLayout {
            for run in line {
                if let mark = run[LinkRunAttribute.self] {
                    runs.append((mark.url, run.typographicBounds.rect))
                }
            }
            context.draw(line)
        }
        layout.runs = runs
    }
}

extension View {
    /// ⌘-hover previews for the links of a Text built with `markingLinks`.
    func linkHoverPreviews() -> some View {
        modifier(LinkHoverPreview())
    }
}

private struct LinkHoverPreview: ViewModifier {
    @Environment(Library.self) private var library
    @State private var layout = LinkRunLayout()
    @State private var hovered: (url: URL, rect: CGRect)?
    @State private var preview: Preview?
    @State private var monitor: Any?

    struct Preview: Equatable {
        var path: String
        var title: String
        var rect: CGRect
    }

    func body(content: Content) -> some View {
        content
            .textRenderer(LinkRunRecorder(layout: layout))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let link = layout.link(at: point)
                    if link?.url != hovered?.url { preview = nil }
                    hovered = link
                    if link != nil { watchCommandKey() }
                    update()
                case .ended:
                    hovered = nil
                    preview = nil
                    stopWatching()
                }
            }
            .popover(isPresented: Binding { preview != nil } set: { if !$0 { preview = nil } },
                     attachmentAnchor: .rect(.rect(preview?.rect ?? .zero)), arrowEdge: .bottom) {
                if let preview {
                    NotePreviewCard(path: preview.path, title: preview.title, session: library.session)
                }
            }
            .onDisappear(perform: stopWatching)
    }

    /// Shows the hovered link's note once ⌘ is down; it stays until the
    /// pointer leaves the link.
    private func update() {
        guard let hovered, preview == nil, NSEvent.modifierFlags.contains(.command),
              case .note(let id, _, _) = WikiLinkAction(url: hovered.url),
              let session = library.session else { return }
        let rect = hovered.rect
        let url = hovered.url
        Task {
            guard let note = try? await session.notes.summary(id: id), self.hovered?.url == url else { return }
            preview = Preview(path: note.path, title: note.title, rect: rect)
        }
    }

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
