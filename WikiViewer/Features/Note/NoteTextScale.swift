//
//  NoteTextScale.swift
//  WikiViewer
//
//  The size of note text. iOS follows Dynamic Type; macOS has none (a
//  `dynamicTypeSize` is ignored there), so the reader picks a scale with
//  ⌘+ / ⌘- / ⌘0 and note text is drawn at the text style's size times it.
//

import SwiftUI
import WikiViewerKit
#if os(macOS)
import AppKit
#endif

enum NoteTextScale {
    static let defaultsKey = "WikiViewer.noteTextScale"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    static var current: Double {
        let value = UserDefaults.standard.double(forKey: defaultsKey)
        return value > 0 ? value : 1
    }

    static func step(_ direction: Int) {
        let index = steps.firstIndex { $0 >= current - 0.001 } ?? 1
        let next = steps[min(max(index + direction, 0), steps.count - 1)]
        UserDefaults.standard.set(next, forKey: defaultsKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static var canEnlarge: Bool { current < steps.last! - 0.001 }
    static var canReduce: Bool { current > steps.first! + 0.001 }

    static func font(_ style: Font.TextStyle, design: Font.Design, weight: Font.Weight?, scale: CGFloat) -> Font {
        var font = Font.system(style, design: design)
        #if os(macOS)
        if scale != 1 {
            let base = NSFont.preferredFont(forTextStyle: style.appKitStyle)
            let size = base.pointSize * scale
            // From the NSFont when the design is the default, so a style
            // with its own weight (headline) keeps it.
            font = design == .default ? Font(base.withSize(size)) : .system(size: size, design: design)
        }
        #endif
        if let weight { font = font.weight(weight) }
        return font
    }

    /// Point size for math set in text of `style`.
    static func mathSize(_ style: MathRenderer.TextStyle, _ typeSize: DynamicTypeSize, scale: CGFloat) -> CGFloat {
        MathRenderer.fontSize(style, typeSize) * scale
    }
}

extension EnvironmentValues {
    /// Note text size relative to the system's (macOS), 1 on iOS.
    @Entry var noteTextScale: CGFloat = 1
}

extension View {
    /// `style` at the reader's note text size.
    func noteFont(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil) -> some View {
        modifier(NoteFont(style: style, design: design, weight: weight))
    }
}

private struct NoteFont: ViewModifier {
    let style: Font.TextStyle
    let design: Font.Design
    let weight: Font.Weight?
    @Environment(\.noteTextScale) private var scale

    func body(content: Content) -> some View {
        content.font(NoteTextScale.font(style, design: design, weight: weight, scale: scale))
    }
}

#if os(macOS)
private extension Font.TextStyle {
    var appKitStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif
