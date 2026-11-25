//
//  FootnotePreview.swift
//  WikiViewer
//
//  A footnote's definition in a popover over its reference, so it can be
//  read without scrolling to it: long-press the reference on iOS, hold ⌘
//  over it on macOS (LinkHoverPreview). A tap still scrolls to the
//  definition.
//

import SwiftUI
import WikiViewerKit
#if canImport(UIKit)
import UIKit
#endif

/// The footnotes of the note on screen. A class compared by identity: it
/// is in the environment of every block, and comparing renderings would
/// cost as much as redrawing them.
final class FootnoteDefinitions: Equatable, Sendable {
    let noteID: Int64
    let rendered: RenderedNote

    /// Nil for a note without footnotes.
    init?(noteID: Int64?, rendered: RenderedNote) {
        guard let noteID, rendered.blockAnchors.keys.contains(where: { $0.hasPrefix("fn:") }) else { return nil }
        self.noteID = noteID
        self.rendered = rendered
    }

    static func == (lhs: FootnoteDefinitions, rhs: FootnoteDefinitions) -> Bool { lhs === rhs }

    /// The definition `url` (a footnote reference's link) points to; nil
    /// for any other link, including a footnote of an embedded note.
    func definition(for url: URL) -> [RenderBlock]? {
        rendered.footnoteDefinition(for: url, noteID: noteID)
    }
}

extension EnvironmentValues {
    @Entry var footnoteDefinitions: FootnoteDefinitions?
}

/// A footnote's definition, as shown in a popover.
struct FootnoteCard: View {
    let blocks: [RenderBlock]
    /// Closes the popover: following a link in it leaves the reference.
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { BlockView(block: $0) }
        }
        .padding(14)
        .frame(minWidth: 200, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, OpenURLAction { url in
            close()
            openURL(url)
            return .handled
        })
    }
}

extension View {
    /// Footnote previews for the references in a Text built with
    /// `markingLinks` (iOS: long-press). macOS shows them with its link
    /// previews.
    @ViewBuilder
    func footnotePreviews(_ enabled: Bool) -> some View {
        #if canImport(UIKit)
        if enabled {
            modifier(FootnotePressPreview())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct FootnotePressPreview: ViewModifier {
    @Environment(\.footnoteDefinitions) private var footnotes
    @State private var layout = LinkRunLayout()
    @State private var shown: Shown?

    struct Shown {
        var blocks: [RenderBlock]
        var rect: CGRect
    }

    func body(content: Content) -> some View {
        content
            .textRenderer(LinkRunRecorder(layout: layout))
            .gesture(FootnotePress(layout: layout, footnotes: footnotes) { blocks, rect in
                shown = Shown(blocks: blocks, rect: rect)
            })
            .popover(isPresented: Binding { shown != nil } set: { if !$0 { shown = nil } },
                     attachmentAnchor: .rect(.rect(shown?.rect ?? .zero)), arrowEdge: .bottom) {
                if let shown {
                    FootnoteCard(blocks: shown.blocks) { self.shown = nil }
                        .presentationCompactAdaptation(.popover)
                }
            }
    }
}

/// A long press that begins only on a footnote reference, so a long press
/// elsewhere still selects text or opens a link's menu.
private struct FootnotePress: UIGestureRecognizerRepresentable {
    let layout: LinkRunLayout
    let footnotes: FootnoteDefinitions?
    let onPress: ([RenderBlock], CGRect) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        // Sooner than text selection's long press, which it replaces here.
        recognizer.minimumPressDuration = 0.35
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.footnote = { point in footnote(at: point) }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        guard recognizer.state == .began, let (blocks, rect) = footnote(at: context.converter.localLocation) else { return }
        onPress(blocks, rect)
    }

    private func footnote(at point: CGPoint) -> ([RenderBlock], CGRect)? {
        guard let link = layout.link(at: point), let blocks = footnotes?.definition(for: link.url) else { return nil }
        return (blocks, link.rect)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var footnote: (CGPoint) -> ([RenderBlock], CGRect)? = { _ in nil }

        init(converter: CoordinateSpaceConverter) {
            self.converter = converter
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            footnote(converter.localLocation) != nil
        }
    }
}
#endif
