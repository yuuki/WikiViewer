//
//  LinkRunLayout.swift
//  WikiViewer
//
//  SwiftUI does not say which link of a Text is under a pointer or finger,
//  so the text is built with each link run marked
//  (`Text(math:markingLinks:)`), a TextRenderer records where those runs
//  were laid out, and the point is looked up among them. Used by link
//  previews on macOS and footnote previews.
//

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
