//
//  GraphCanvas.swift
//  WikiViewer
//
//  An interactive node-link drawing: pan with one finger, pinch to zoom,
//  tap to select; on a Mac the mouse wheel zooms too, and a trackpad's
//  two-finger scroll pans. Touch has no hover, so selection does what hover
//  does in wiki-lens: it brings out a node's links and neighbours and dims
//  the rest.
//  With a pointer (macOS, iPad), hovering a node does the same while
//  nothing is selected.
//
//  Everything is drawn into one Canvas from a few hundred nodes at most (the
//  repositories bound what a screen loads). Labels are placed greedily by
//  priority and skipped where they would collide, so zooming in reveals more
//  names instead of piling them up.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct GraphScene {
    struct Node: Identifiable {
        enum Style {
            /// A note: a filled dot of constant screen size.
            case dot
            /// The note a local graph is centred on.
            case center
            /// A link target that does not exist: a dashed ring.
            case missing
            /// A cluster on the overview: a translucent bubble whose size is
            /// in world units, labelled inside.
            case bubble
        }

        var id: Int64
        /// World coordinates.
        var position: CGPoint
        /// Points for dots, world units for bubbles.
        var radius: CGFloat
        var color: Color
        var label: String
        var sublabel: String? = nil
        /// Higher is labelled first.
        var priority: Double
        var style: Style = .dot
    }

    struct Edge {
        var a: Int64
        var b: Int64
        /// Line width in points.
        var width: CGFloat = 0.6
        /// Hidden unless one end is selected (e.g. the overview's minor links).
        var onlyWhenSelected = false
    }

    var nodes: [Node]
    var edges: [Edge]
    let index: [Int64: Int]
    /// Nodes by label priority.
    let labelOrder: [Int]
    let bounds: CGRect

    init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
        index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        labelOrder = nodes.indices.sorted { nodes[$0].priority > nodes[$1].priority }
        var rect = CGRect.null
        for n in nodes {
            let r = n.style == .bubble ? n.radius : 0
            rect = rect.union(CGRect(x: n.position.x - r, y: n.position.y - r, width: 2 * r, height: 2 * r))
        }
        bounds = rect.isNull ? CGRect(x: -1, y: -1, width: 2, height: 2) : rect
    }

    func neighbours(of id: Int64) -> Set<Int64> {
        var result: Set<Int64> = [id]
        for e in edges {
            if e.a == id { result.insert(e.b) } else if e.b == id { result.insert(e.a) }
        }
        return result
    }
}

/// Maps world coordinates to the view: `scale` points per world unit, with
/// `center` in the middle of the view.
struct GraphCamera: Equatable {
    var center: CGPoint
    var scale: CGFloat

    func screen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: (p.y - center.y) * scale + size.height / 2)
    }

    func world(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / scale + center.x, y: (p.y - size.height / 2) / scale + center.y)
    }

    func zoomed(by factor: CGFloat, around anchor: CGPoint, in size: CGSize, limits: ClosedRange<CGFloat>) -> GraphCamera {
        let newScale = min(max(scale * factor, limits.lowerBound), limits.upperBound)
        let fixed = world(anchor, in: size)
        return GraphCamera(center: CGPoint(x: fixed.x - (anchor.x - size.width / 2) / newScale,
                                           y: fixed.y - (anchor.y - size.height / 2) / newScale),
                           scale: newScale)
    }

    func panned(by t: CGSize) -> GraphCamera {
        GraphCamera(center: CGPoint(x: center.x - t.width / scale, y: center.y - t.height / scale), scale: scale)
    }

    /// `rect` in the middle of the view, `padding` from its top and bottom
    /// and more from its sides: labels are centred under their nodes, so
    /// the outermost ones reach past them.
    static func fitting(_ rect: CGRect, in size: CGSize, padding: CGFloat = 36) -> GraphCamera {
        let w = max(rect.width, 1e-6), h = max(rect.height, 1e-6)
        let side = max(padding, min(2 * padding, size.width / 8))
        let scale = min((size.width - 2 * side) / w, (size.height - 2 * padding) / h)
        return GraphCamera(center: CGPoint(x: rect.midX, y: rect.midY), scale: max(scale, 1e-3))
    }

    func interpolated(to other: GraphCamera, _ t: CGFloat) -> GraphCamera {
        // Interpolate the scale geometrically so zooming feels even.
        let s = exp(log(scale) * (1 - t) + log(other.scale) * t)
        return GraphCamera(center: CGPoint(x: center.x + (other.center.x - center.x) * t, y: center.y + (other.center.y - center.y) * t), scale: s)
    }
}

struct GraphCanvas: View {
    let scene: GraphScene
    let selection: Int64?
    /// Changing it re-fits the whole scene into view.
    var fitKey: AnyHashable = 0
    /// Brought to the middle of the view (zoomed in) when it changes.
    var focus: Int64? = nil
    /// Labels drawn at most on a phone-sized view; a larger view (a Mac
    /// window) draws proportionally more, up to four times as many.
    var labelBudget = 40
    /// A double-click on a node (macOS): what a second tap on the selected
    /// node does on a phone, or opening it.
    var onDoubleClick: ((Int64) -> Void)? = nil
    let onTap: (Int64?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var size: CGSize = .zero
    @State private var camera = GraphCamera(center: .zero, scale: 1)
    @State private var fitScale: CGFloat = 1
    @State private var fittedKey: AnyHashable?
    // A pan and a pinch can run together; both are applied to the camera
    // they started from and committed when both end.
    @State private var gestureBase: GraphCamera?
    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGPoint = .zero
    @State private var panning = false
    @State private var pinching = false
    @State private var animation: CameraAnimation?
    /// The node under the pointer.
    @State private var hovered: Int64?
    #if os(macOS)
    /// Where the pointer is over the view, for zooming around it.
    @State private var pointer: CGPoint?
    @State private var scrollMonitor: Any?
    #endif

    struct CameraAnimation: Equatable {
        var from: GraphCamera
        var to: GraphCamera
        var start: Date
        var duration: Double = 0.45

        func value(at date: Date) -> GraphCamera {
            let t = min(max(date.timeIntervalSince(start) / duration, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            return from.interpolated(to: to, eased)
        }
    }

    /// The area of an iPhone in portrait, which `labelBudget` is for.
    private static let budgetArea: CGFloat = 390 * 700

    private var effectiveLabelBudget: Int {
        let factor = min(max(size.width * size.height / Self.budgetArea, 1), 4)
        return Int((CGFloat(labelBudget) * factor).rounded())
    }

    private var scaleLimits: ClosedRange<CGFloat> { (fitScale * 0.4)...(fitScale * 60) }

    private var liveCamera: GraphCamera {
        guard let gestureBase else { return camera }
        return gestureBase.zoomed(by: zoom, around: zoomAnchor, in: size, limits: scaleLimits).panned(by: pan)
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: animation == nil)) { timeline in
                let cam = animation?.value(at: timeline.date) ?? liveCamera
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size, camera: cam)
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture.simultaneously(with: pinchGesture))
            .onTapGesture(coordinateSpace: .local) { location in
                onTap(hit(location))
            }
            #if os(macOS)
            // Alongside the single click, which has selected the node by
            // the second click.
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                if let onDoubleClick, let node = hit(value.location) { onDoubleClick(node) }
            })
            #endif
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hovered = gestureBase == nil ? hit(location) : nil
                    #if os(macOS)
                    pointer = location
                    watchScrolling()
                    #endif
                case .ended:
                    hovered = nil
                    #if os(macOS)
                    pointer = nil
                    stopWatchingScrolling()
                    #endif
                }
            }
            #if os(macOS)
            .pointerStyle(hovered == nil ? .default : .link)
            .onDisappear(perform: stopWatchingScrolling)
            #endif
            .onAppear { layout(size: proxy.size) }
            .onChange(of: proxy.size) { layout(size: proxy.size) }
        }
        .onChange(of: fitKey) { fit(animated: true) }
        .onChange(of: focus) { if let focus { center(on: focus) } }
        .task(id: animation) {
            guard let animation else { return }
            try? await Task.sleep(for: .seconds(animation.duration))
            if self.animation == animation {
                camera = animation.to
                self.animation = nil
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFitted {
                Button("Show All", systemImage: "arrow.up.left.and.arrow.down.right") { fit(animated: true) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .padding(12)
            }
        }
    }

    private var isFitted: Bool {
        let fitted = GraphCamera.fitting(scene.bounds, in: size)
        return abs(camera.scale / fitted.scale - 1) < 0.05 && hypot(camera.center.x - fitted.center.x, camera.center.y - fitted.center.y) * camera.scale < 20
    }

    // MARK: Camera

    private func layout(size newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let first = size == .zero
        // Showing the whole graph: go on showing it in the new size (the
        // window resized, the inspector opened).
        let wasFitted = !first && animation == nil && isFitted
        size = newSize
        fitScale = GraphCamera.fitting(scene.bounds, in: newSize).scale
        if first || fittedKey != fitKey {
            fit(animated: false)
            if let focus { center(on: focus, animated: false) }
        } else if wasFitted {
            fit(animated: false)
        }
    }

    private func fit(animated: Bool) {
        guard size != .zero else { return }
        fittedKey = fitKey
        let target = GraphCamera.fitting(scene.bounds, in: size)
        fitScale = target.scale
        move(to: target, animated: animated)
    }

    private func center(on id: Int64, animated: Bool = true) {
        guard let i = scene.index[id], size != .zero else { return }
        let node = scene.nodes[i]
        var target = GraphCamera(center: node.position, scale: max(camera.scale, fitScale * 2.5))
        if node.style == .bubble {
            target.scale = min(size.width, size.height) / (node.radius * 5)
        }
        target.scale = min(max(target.scale, scaleLimits.lowerBound), scaleLimits.upperBound)
        move(to: target, animated: animated)
    }

    private func move(to target: GraphCamera, animated: Bool) {
        if animated {
            animation = CameraAnimation(from: animation?.value(at: .now) ?? camera, to: target, start: .now)
        } else {
            animation = nil
            camera = target
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                beginGesture()
                panning = true
                pan = value.translation
            }
            .onEnded { _ in
                panning = false
                endGesture()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                beginGesture()
                if !pinching { zoomAnchor = value.startLocation }
                pinching = true
                zoom = value.magnification
            }
            .onEnded { _ in
                pinching = false
                endGesture()
            }
    }

    #if os(macOS)
    /// A mouse wheel zooms around the pointer; a trackpad's two-finger
    /// scroll pans, and zooms with ⌘ or ⌥ held (the pinch zooms too).
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pointer, gestureBase == nil, size != .zero else { return event }
            if let animation {
                camera = animation.value(at: .now)
                self.animation = nil
            }
            let zooms = !event.hasPreciseScrollingDeltas || !event.modifierFlags.intersection([.command, .option]).isEmpty
            if zooms {
                // A wheel's notch is about one line; a trackpad's delta is
                // points. Away from the reader zooms in, whichever way the
                // system scrolls content (natural scrolling inverts it).
                let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
                let steps = event.hasPreciseScrollingDeltas ? delta / 10 : delta
                camera = camera.zoomed(by: pow(1.15, steps), around: pointer, in: size, limits: scaleLimits)
            } else {
                camera = camera.panned(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            }
            return nil
        }
    }

    private func stopWatchingScrolling() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    #endif

    private func beginGesture() {
        guard gestureBase == nil else { return }
        if let animation { camera = animation.value(at: .now) }
        animation = nil
        gestureBase = camera
    }

    private func endGesture() {
        guard !panning, !pinching, gestureBase != nil else { return }
        camera = liveCamera
        gestureBase = nil
        pan = .zero
        zoom = 1
    }

    // MARK: Hit testing

    private func hit(_ location: CGPoint) -> Int64? {
        let cam = liveCamera
        var best: (Int64, CGFloat)?
        for node in scene.nodes {
            let p = cam.screen(node.position, in: size)
            let d = hypot(p.x - location.x, p.y - location.y)
            let reach = max(screenRadius(node, cam), 22)
            if d <= reach, best == nil || d < best!.1 { best = (node.id, d) }
        }
        return best?.0
    }

    private func screenRadius(_ node: GraphScene.Node, _ cam: GraphCamera) -> CGFloat {
        switch node.style {
        case .bubble: max(node.radius * cam.scale, 3)
        case .center: node.radius + 3
        case .dot, .missing: node.radius * min(max(cam.scale / fitScale, 1), 1.8)
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, camera cam: GraphCamera) {
        // A hovered node is emphasised like a selected one.
        let selection = selection ?? hovered
        let highlighted = selection.map(scene.neighbours(of:))
        func isDimmed(_ id: Int64) -> Bool { highlighted.map { !$0.contains(id) } ?? false }
        let edgeColor = Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16)
        let viewRect = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

        // Links: faint by default; around a selection only its own links,
        // in the selected node's colour.
        var normal = Path()
        var accent = Path()
        var accentWidth: CGFloat = 1.2
        for edge in scene.edges {
            guard let ia = scene.index[edge.a], let ib = scene.index[edge.b] else { continue }
            let touchesSelection = selection != nil && (edge.a == selection || edge.b == selection)
            if edge.onlyWhenSelected && !touchesSelection { continue }
            // Bubble links stop at the rims, clear of the labels inside.
            guard let (a, b) = Self.trimmed(cam.screen(scene.nodes[ia].position, in: size),
                                             cam.screen(scene.nodes[ib].position, in: size),
                                             scene.nodes[ia].style == .bubble ? screenRadius(scene.nodes[ia], cam) : 0,
                                             scene.nodes[ib].style == .bubble ? screenRadius(scene.nodes[ib], cam) : 0) else { continue }
            guard viewRect.contains(a) || viewRect.contains(b) || CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersects(viewRect) else { continue }
            if touchesSelection {
                accent.move(to: a)
                accent.addLine(to: b)
                accentWidth = max(accentWidth, edge.width * 1.4)
            } else if selection == nil || edge.width > 1 {
                if edge.width > 1 {
                    // Weighted overview links are few: stroke each on its own.
                    var p = Path()
                    p.move(to: a)
                    p.addLine(to: b)
                    context.stroke(p, with: .color(edgeColor.opacity(selection == nil ? 1 : 0.35)), lineWidth: edge.width)
                } else {
                    normal.move(to: a)
                    normal.addLine(to: b)
                }
            }
        }
        context.stroke(normal, with: .color(edgeColor), lineWidth: 0.6)
        let selectedColor = selection.flatMap { scene.index[$0] }.map { scene.nodes[$0].color } ?? .accentColor
        context.stroke(accent, with: .color(selectedColor.opacity(0.85)), lineWidth: accentWidth)

        // Nodes.
        let background = Color.platformBackground
        for node in scene.nodes {
            let p = cam.screen(node.position, in: size)
            let r = screenRadius(node, cam)
            guard viewRect.insetBy(dx: -r, dy: -r).contains(p) else { continue }
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let circle = Path(ellipseIn: rect)
            let dimmed = isDimmed(node.id)
            let alpha: Double = dimmed ? 0.18 : 1
            switch node.style {
            case .bubble:
                context.fill(circle, with: .color(node.color.opacity(0.28 * alpha)))
                context.stroke(circle, with: .color(node.color.opacity(alpha)), lineWidth: node.id == selection ? 3 : 1.5)
            case .dot:
                context.fill(circle, with: .color(node.color.opacity(alpha)))
                context.stroke(circle, with: .color(background.opacity(alpha)), lineWidth: 0.8)
            case .center:
                context.fill(circle, with: .color(node.color))
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary.opacity(0.8)), lineWidth: 2)
            case .missing:
                context.fill(circle, with: .color(background.opacity(alpha)))
                context.stroke(circle, with: .color(node.color.opacity(alpha)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
            if node.id == selection, node.style != .bubble {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(.primary), lineWidth: 2)
            }
        }

        drawLabels(in: &context, size: size, camera: cam, highlighted: highlighted)
    }

    private func drawLabels(in context: inout GraphicsContext, size: CGSize, camera cam: GraphCamera, highlighted: Set<Int64>?) {
        let selection = selection ?? hovered
        let screenRect = CGRect(origin: .zero, size: size)
        var placed: [CGRect] = []
        var order: [Int] = []
        // The selection and its neighbours are named first.
        if let selection, let i = scene.index[selection] { order.append(i) }
        if let highlighted {
            order += scene.labelOrder.filter { highlighted.contains(scene.nodes[$0].id) && scene.nodes[$0].id != selection }
            order += scene.labelOrder.filter { !highlighted.contains(scene.nodes[$0].id) }
        } else {
            order += scene.labelOrder
        }
        var attempts = 0
        for i in order {
            guard placed.count < effectiveLabelBudget, attempts < 300 else { break }
            let node = scene.nodes[i]
            let dimmed = highlighted.map { !$0.contains(node.id) } ?? false
            if dimmed { continue }
            let p = cam.screen(node.position, in: size)
            guard screenRect.contains(p) else { continue }
            attempts += 1
            let isSelected = node.id == selection
            let text = isSelected ? node.label : Self.truncated(node.label, to: node.style == .bubble ? 16 : 22)
            let fontSize: CGFloat = node.style == .bubble ? 13 : (node.style == .center || isSelected ? 13 : 11)
            let width = Self.estimatedWidth(text, fontSize: fontSize) + 8
            let lines: CGFloat = node.sublabel == nil ? 1 : 2
            let height = (fontSize + 4) * lines + 2
            let r = screenRadius(node, cam)
            let origin: CGPoint
            if node.style == .bubble {
                // Inside the bubble when it fits, otherwise below it.
                origin = r * 2 > height + 4 ? CGPoint(x: p.x - width / 2, y: p.y - height / 2) : CGPoint(x: p.x - width / 2, y: p.y + r + 2)
            } else {
                origin = CGPoint(x: p.x - width / 2, y: p.y + r + 3)
            }
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
            if !isSelected, placed.contains(where: { $0.intersects(rect) }) { continue }
            placed.append(rect)

            if node.style != .bubble || !(r * 2 > height + 4) {
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color.platformBackground.opacity(0.82)))
            }
            let color: Color = node.style == .missing ? GraphPalette.missing : .primary
            let weight: Font.Weight = node.style == .bubble || isSelected || node.style == .center ? .semibold : .regular
            let title = context.resolve(Text(text).font(.system(size: fontSize, weight: weight)).foregroundStyle(color))
            if let sub = node.sublabel {
                let lineHeight = (height - 2) / 2
                context.draw(title, at: CGPoint(x: rect.midX, y: rect.minY + 1 + lineHeight / 2), anchor: .center)
                let subtitle = context.resolve(Text(sub).font(.system(size: fontSize - 2)).foregroundStyle(.secondary))
                context.draw(subtitle, at: CGPoint(x: rect.midX, y: rect.minY + 1 + lineHeight * 1.5), anchor: .center)
            } else {
                context.draw(title, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }

    /// The segment a–b less `ra` at a's end and `rb` at b's; nil when the
    /// circles overlap and nothing would be left.
    static func trimmed(_ a: CGPoint, _ b: CGPoint, _ ra: CGFloat, _ rb: CGFloat) -> (CGPoint, CGPoint)? {
        guard ra > 0 || rb > 0 else { return (a, b) }
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > ra + rb else { return nil }
        let ux = dx / length, uy = dy / length
        return (CGPoint(x: a.x + ux * ra, y: a.y + uy * ra), CGPoint(x: b.x - ux * rb, y: b.y - uy * rb))
    }

    static func truncated(_ s: String, to limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    /// Rough label width without laying text out: CJK and other wide
    /// characters take about a full em, ASCII about half.
    static func estimatedWidth(_ s: String, fontSize: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        for scalar in s.unicodeScalars {
            width += scalar.value < 0x2E80 ? (scalar.value < 0x80 ? 0.56 : 0.7) : 1.0
        }
        return width * fontSize
    }
}
