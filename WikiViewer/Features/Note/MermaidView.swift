//
//  MermaidView.swift
//  WikiViewer
//
//  Draws a Mermaid flowchart natively: MermaidLayout places it, a Canvas
//  draws it. Labels are measured with the platform font they are drawn in.
//  A chart wider than the page is scaled down to fit, to a limit, and
//  scrolls sideways beyond it. A tap opens the whole chart full screen,
//  where it zooms and pans like an image.
//

import SwiftUI
import WikiViewerKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct MermaidView: View {
    @Environment(\.noteTextScale) private var noteTextScale
    @Environment(\.dynamicTypeSize) private var typeSize
    let chart: MermaidFlowchart
    let source: String
    @State private var availableWidth: CGFloat?
    @State private var showingFullScreen = false

    /// Smaller than this, labels get hard to read: scroll instead.
    static let minimumScale: CGFloat = 0.7

    var body: some View {
        let fontSize = NoteTextScale.mathSize(.noteDetail, typeSize, scale: noteTextScale)
        let layout = MermaidLayoutCache.layout(chart, source: source, fontSize: fontSize)
        let fit = availableWidth.map { min(1, $0 / max(layout.size.width, 1)) } ?? 1
        let scale = max(fit, Self.minimumScale)
        let diagram = MermaidCanvas(layout: layout, fontSize: fontSize, scale: scale)
            .frame(width: layout.size.width * scale, height: layout.size.height * scale)
        Group {
            if fit >= Self.minimumScale {
                diagram.frame(maxWidth: .infinity)
            } else {
                HorizontalScroll { diagram }
                    .overlay(alignment: .topTrailing) {
                        // Says that part of the chart is out of view.
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .noteFont(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.regularMaterial, in: .circle)
                            .accessibilityHidden(true)
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture { showingFullScreen = true }
        .contextMenu {
            Button("Show Whole Chart", systemImage: "arrow.up.left.and.arrow.down.right") {
                showingFullScreen = true
            }
            Button("Copy Mermaid Source", systemImage: "doc.on.doc") {
                Pasteboard.copy(source)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Flowchart"))
        .accessibilityValue(Text(verbatim: chart.plainText))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Shows the whole chart"))
        #if os(iOS)
        .fullScreenCover(isPresented: $showingFullScreen) {
            MermaidViewer(layout: layout, fontSize: fontSize, source: source)
        }
        #else
        .sheet(isPresented: $showingFullScreen) {
            MermaidViewer(layout: layout, fontSize: fontSize, source: source)
                .frame(minWidth: 600, idealWidth: 900, minHeight: 450, idealHeight: 700)
        }
        #endif
    }
}

/// The whole chart, fitted to the screen: pinch or double-tap to zoom in,
/// drag to pan. Drawn once into an image, so zooming stays smooth.
private struct MermaidViewer: View {
    let layout: MermaidLayout
    let fontSize: CGFloat
    let source: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: CGImage?

    /// Sharp at 3× zoom, bounded so a huge chart never becomes a huge bitmap.
    static let maxPixelSize: CGFloat = 6144

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image, scale: renderScale, label: String(localized: "Flowchart"))
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformBackground)
            .navigationTitle("Flowchart")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy Mermaid Source", systemImage: "doc.on.doc") {
                        Pasteboard.copy(source)
                    }
                }
            }
        }
        .task(id: colorScheme) { render() }
    }

    private var renderScale: CGFloat {
        let side = max(layout.size.width, layout.size.height, 1)
        return min(displayScale * 3, Self.maxPixelSize / side)
    }

    private func render() {
        let renderer = ImageRenderer(content: MermaidCanvas(layout: layout, fontSize: fontSize, scale: 1)
            .frame(width: layout.size.width, height: layout.size.height)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = renderScale
        image = renderer.cgImage
    }
}

/// Layouts by source and font size, so scrolling back to a chart does not
/// lay it out again.
@MainActor
enum MermaidLayoutCache {
    private final class Entry {
        let layout: MermaidLayout
        init(_ layout: MermaidLayout) { self.layout = layout }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 50
        return cache
    }()

    static func layout(_ chart: MermaidFlowchart, source: String, fontSize: CGFloat) -> MermaidLayout {
        let key = "\(fontSize)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.layout }
        let layout = MermaidLayout(chart: chart, fontSize: fontSize) { MermaidText.size($0, fontSize: fontSize) }
        cache.setObject(Entry(layout), forKey: key)
        return layout
    }
}

enum MermaidText {
    /// Labels wrap at about 16 characters' width, as Mermaid wraps at 200 px.
    static func maxWidth(_ fontSize: CGFloat) -> CGFloat { fontSize * 16 }

    static func size(_ text: String, fontSize: CGFloat) -> CGSize {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: fontSize)
        #else
        let font = NSFont.systemFont(ofSize: fontSize)
        #endif
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let rect = string.boundingRect(with: CGSize(width: maxWidth(fontSize), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        // A little slack, so the drawn Text does not wrap differently.
        return CGSize(width: rect.width.rounded(.up) + 2, height: rect.height.rounded(.up))
    }
}

private struct MermaidCanvas: View {
    let layout: MermaidLayout
    let fontSize: CGFloat
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            for cluster in layout.clusters { draw(cluster, in: context) }
            for edge in layout.edges { draw(edge, in: context) }
            for node in layout.nodes { draw(node, in: context) }
        } symbols: {
            // Labels as views: text drawn directly into a Canvas cannot
            // center its lines.
            ForEach(labels, id: \.self) { key in
                Text(verbatim: key.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(key.secondary ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.center)
                    .frame(width: MermaidText.size(key.text, fontSize: fontSize).width)
                    .tag(key)
            }
        }
    }

    private struct LabelKey: Hashable {
        var text: String
        var secondary: Bool
    }

    private var labels: [LabelKey] {
        var seen = Set<LabelKey>()
        let all = layout.clusters.map { LabelKey(text: $0.title, secondary: true) }
            + layout.nodes.map { LabelKey(text: $0.label, secondary: false) }
            + layout.edges.compactMap { $0.label.map { LabelKey(text: $0, secondary: true) } }
        return all.filter { !$0.text.isEmpty && seen.insert($0).inserted }
    }

    private var unit: CGFloat { fontSize }
    private var strokeColor: Color { .secondary }

    private func label(_ text: String, at center: CGPoint, secondary: Bool = false, in context: GraphicsContext) {
        guard let symbol = context.resolveSymbol(id: LabelKey(text: text, secondary: secondary)) else { return }
        context.draw(symbol, at: center, anchor: .center)
    }

    private func draw(_ cluster: MermaidLayout.Cluster, in context: GraphicsContext) {
        let path = Path(roundedRect: cluster.frame, cornerRadius: unit * 0.4)
        context.fill(path, with: .color(Color.primary.opacity(0.04)))
        context.stroke(path, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
        if !cluster.title.isEmpty {
            label(cluster.title, at: cluster.titleCenter, secondary: true, in: context)
        }
    }

    private func draw(_ node: MermaidLayout.Node, in context: GraphicsContext) {
        // The asset itself: ImageRenderer (MermaidViewer) does not resolve
        // Color.accentColor to the app's accent.
        let fill = GraphicsContext.Shading.color(Color("AccentColor").opacity(0.12))
        let stroke = GraphicsContext.Shading.color(Color("AccentColor").opacity(0.7))
        // Opaque under the tint, so edges and clusters do not show through.
        let background = GraphicsContext.Shading.color(Color.platformBackground)
        let (outline, detail) = Self.shape(node.shape, in: node.frame, unit: unit)
        context.fill(outline, with: background)
        context.fill(outline, with: fill)
        context.stroke(outline, with: stroke, lineWidth: 1.2)
        if let detail { context.stroke(detail, with: stroke, lineWidth: 1.2) }
        let rect = node.frame
        var center = CGPoint(x: rect.midX, y: rect.midY)
        if node.shape == .cylinder { center.y += unit * 0.25 }
        label(node.label, at: center, in: context)
    }

    private func draw(_ edge: MermaidLayout.Edge, in context: GraphicsContext) {
        guard edge.stroke != .invisible, edge.points.count >= 2 else { return }
        var points = edge.points
        let arrowLength = unit * 0.6
        // The line stops short of an arrow head, so the tip stays sharp.
        if edge.head == .arrow { points[points.count - 1] = Self.pulled(points[points.count - 1], toward: points[points.count - 2], by: arrowLength * 0.8) }
        if edge.tail == .arrow { points[0] = Self.pulled(points[0], toward: points[1], by: arrowLength * 0.8) }
        var path = Path()
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let next = points[i + 1]
            path.addQuadCurve(to: CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2), control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        let width: CGFloat = edge.stroke == .thick ? 2.4 : 1.2
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: edge.stroke == .dotted ? [3, 3] : [])
        context.stroke(path, with: .color(strokeColor), style: style)

        let all = edge.points
        if let head = edge.head { drawHead(head, tip: all[all.count - 1], from: all[all.count - 2], length: arrowLength, in: context) }
        if let tail = edge.tail { drawHead(tail, tip: all[0], from: all[1], length: arrowLength, in: context) }

        if let text = edge.label, let frame = edge.labelFrame {
            let box = Path(roundedRect: frame.insetBy(dx: -3, dy: -1), cornerRadius: 3)
            context.fill(box, with: .color(Color.platformBackground))
            label(text, at: CGPoint(x: frame.midX, y: frame.midY), secondary: true, in: context)
        }
    }

    private func drawHead(_ head: MermaidFlowchart.ArrowHead, tip: CGPoint, from: CGPoint, length: CGFloat, in context: GraphicsContext) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / distance, uy = dy / distance
        switch head {
        case .arrow:
            let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
            let half = length * 0.45
            var path = Path()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            path.closeSubpath()
            context.fill(path, with: .color(strokeColor))
        case .circle:
            let r = length * 0.3
            let center = CGPoint(x: tip.x - ux * r, y: tip.y - uy * r)
            let path = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            context.fill(path, with: .color(Color.platformBackground))
            context.stroke(path, with: .color(strokeColor), lineWidth: 1.2)
        case .cross:
            let r = length * 0.3
            let center = CGPoint(x: tip.x - ux * r * 1.5, y: tip.y - uy * r * 1.5)
            var path = Path()
            path.move(to: CGPoint(x: center.x - r, y: center.y - r))
            path.addLine(to: CGPoint(x: center.x + r, y: center.y + r))
            path.move(to: CGPoint(x: center.x - r, y: center.y + r))
            path.addLine(to: CGPoint(x: center.x + r, y: center.y - r))
            context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
        }
    }

    static func pulled(_ point: CGPoint, toward other: CGPoint, by amount: CGFloat) -> CGPoint {
        let dx = other.x - point.x, dy = other.y - point.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > amount else { return point }
        return CGPoint(x: point.x + dx / distance * amount, y: point.y + dy / distance * amount)
    }

    /// The outline of a node shape filling `r`, and lines drawn inside it.
    static func shape(_ shape: MermaidFlowchart.Shape, in r: CGRect, unit: CGFloat) -> (Path, Path?) {
        func polygon(_ points: [CGPoint]) -> Path {
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            return path
        }
        let slant = r.height / 2
        switch shape {
        case .rectangle:
            return (Path(roundedRect: r, cornerRadius: 2), nil)
        case .rounded:
            return (Path(roundedRect: r, cornerRadius: min(unit * 0.5, r.height / 2)), nil)
        case .stadium:
            return (Path(roundedRect: r, cornerRadius: r.height / 2), nil)
        case .subroutine:
            var lines = Path()
            let inset = unit * 0.5
            lines.move(to: CGPoint(x: r.minX + inset, y: r.minY))
            lines.addLine(to: CGPoint(x: r.minX + inset, y: r.maxY))
            lines.move(to: CGPoint(x: r.maxX - inset, y: r.minY))
            lines.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY))
            return (Path(r), lines)
        case .cylinder:
            // Half ellipses as two quarter Béziers each.
            let rx = r.width / 2, ry = unit * 0.25, k: CGFloat = 0.5523
            let top = r.minY + ry, bottom = r.maxY - ry
            func lowerHalf(_ path: inout Path, _ y: CGFloat) {
                path.addCurve(to: CGPoint(x: r.midX, y: y + ry), control1: CGPoint(x: r.minX, y: y + k * ry), control2: CGPoint(x: r.midX - k * rx, y: y + ry))
                path.addCurve(to: CGPoint(x: r.maxX, y: y), control1: CGPoint(x: r.midX + k * rx, y: y + ry), control2: CGPoint(x: r.maxX, y: y + k * ry))
            }
            var outline = Path()
            outline.move(to: CGPoint(x: r.minX, y: top))
            outline.addLine(to: CGPoint(x: r.minX, y: bottom))
            lowerHalf(&outline, bottom)
            outline.addLine(to: CGPoint(x: r.maxX, y: top))
            outline.addCurve(to: CGPoint(x: r.midX, y: top - ry), control1: CGPoint(x: r.maxX, y: top - k * ry), control2: CGPoint(x: r.midX + k * rx, y: top - ry))
            outline.addCurve(to: CGPoint(x: r.minX, y: top), control1: CGPoint(x: r.midX - k * rx, y: top - ry), control2: CGPoint(x: r.minX, y: top - k * ry))
            outline.closeSubpath()
            var rim = Path()
            rim.move(to: CGPoint(x: r.minX, y: top))
            lowerHalf(&rim, top)
            return (outline, rim)
        case .circle:
            return (Path(ellipseIn: r), nil)
        case .doubleCircle:
            let gap = unit * 0.3
            return (Path(ellipseIn: r), Path(ellipseIn: r.insetBy(dx: gap, dy: gap)))
        case .rhombus:
            return (polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]), nil)
        case .hexagon:
            return (polygon([CGPoint(x: r.minX + slant, y: r.minY), CGPoint(x: r.maxX - slant, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                             CGPoint(x: r.maxX - slant, y: r.maxY), CGPoint(x: r.minX + slant, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]), nil)
        case .parallelogram:
            return (polygon([CGPoint(x: r.minX + slant, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - slant, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]), nil)
        case .parallelogramAlt:
            return (polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - slant, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX + slant, y: r.maxY)]), nil)
        case .trapezoid:
            return (polygon([CGPoint(x: r.minX + slant, y: r.minY), CGPoint(x: r.maxX - slant, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]), nil)
        case .trapezoidAlt:
            return (polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - slant, y: r.maxY), CGPoint(x: r.minX + slant, y: r.maxY)]), nil)
        case .asymmetric:
            return (polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + slant, y: r.midY)]), nil)
        }
    }
}
