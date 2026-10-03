//
//  NotePrinter.swift
//  WikiViewer
//
//  File > Print… (⌘P) on macOS; the print panel's PDF menu saves a PDF.
//  A SwiftUI view does not draw through AppKit's printing, so the note is
//  drawn into a PDF first: block by block at the width of the paper, in
//  light mode and at the base text size, starting a new page before a
//  block that would not fit (one taller than a page runs on over several).
//  Embedded images are decoded first, and wide blocks are drawn unscrolled.
//  PDFKit prints that PDF. The blocks are drawn on the main actor (as
//  ImageRenderer must be), pausing every few blocks so a long note does
//  not stop the app.
//

#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import WikiShared
import WikiViewerKit

@MainActor
enum NotePrinter {
    static let blockSpacing: CGFloat = 10

    /// Set while a note is being laid out: ⌘P again meanwhile is ignored
    /// rather than laying it out twice.
    private(set) static var isPreparing = false

    static func run(_ note: NoteFocus, library: Library) {
        guard let rendered = note.model.rendered, !isPreparing else { return }
        isPreparing = true
        // The note's window, before the reader moves on.
        let window = NSApp.keyWindow
        Task {
            let images = await images(of: note, library: library)
            await print(note, rendered: rendered, images: images, library: library, window: window)
        }
    }

    /// The note's embedded images, decoded at most 2048 pixels wide.
    private static func images(of note: NoteFocus, library: Library) async -> [Int64: CGImage] {
        var images: [Int64: CGImage] = [:]
        for asset in note.model.embeddedAssets.values where asset.kind == .image && asset.blobSHA256 != nil {
            guard let url = try? await library.blobURL(for: asset),
                  let image = await ImageDownsampler.downsampleInBackground(at: url, maxPixelSize: 2048) else { continue }
            images[asset.id] = image
        }
        return images
    }

    private static func print(_ note: NoteFocus, rendered: RenderedNote, images: [Int64: CGImage], library: Library, window: NSWindow?) async {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let data = await pdf(note: note, rendered: rendered, images: images, library: library, info: info)
        isPreparing = false
        guard let data,
              let document = PDFDocument(data: data),
              let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        operation.jobTitle = note.detail.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // A sheet on the note's window, as other apps print.
        if let window, window.isVisible {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// The note laid out on pages of `info`'s paper and margins.
    static func pdf(note: NoteFocus, rendered: RenderedNote, images: [Int64: CGImage], library: Library, info: NSPrintInfo) async -> Data? {
        let paper = info.paperSize
        let frame = CGRect(x: info.leftMargin, y: info.bottomMargin,
                           width: paper.width - info.leftMargin - info.rightMargin,
                           height: paper.height - info.topMargin - info.bottomMargin)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        // Distance from the top of the page's frame to the next block.
        var y: CGFloat = 0
        context.beginPDFPage(nil)
        func place(_ view: some View) {
            let renderer = ImageRenderer(content: view
                .frame(width: frame.width, alignment: .leading)
                .environment(library)
                .environment(\.embeddedAssets, note.model.embeddedAssets)
                .environment(\.printedImages, images)
                .environment(\.isPrinting, true)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: frame.width, height: nil)
            renderer.render { size, draw in
                if y > 0, y + size.height > frame.height {
                    context.endPDFPage()
                    context.beginPDFPage(nil)
                    y = 0
                }
                // A block taller than a page continues on the next ones.
                var shown: CGFloat = 0
                while true {
                    context.saveGState()
                    context.clip(to: frame)
                    context.translateBy(x: frame.minX, y: frame.maxY - y - size.height + shown)
                    draw(context)
                    context.restoreGState()
                    let room = frame.height - y
                    if size.height - shown <= room {
                        y += size.height - shown + blockSpacing
                        break
                    }
                    shown += room
                    context.endPDFPage()
                    context.beginPDFPage(nil)
                    y = 0
                }
            }
        }

        if !NoteView.startsWithTitleHeading(rendered, title: note.detail.title) {
            place(Text(note.detail.title).font(.title.bold()))
        }
        for (index, block) in rendered.blocks.enumerated() {
            place(BlockView(block: block))
            // A turn of the run loop now and then, for the app's events.
            if index % 8 == 7 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
#endif
