//
//  MathRenderer.swift
//  WikiViewerKit
//
//  Typesets LaTeX with SwiftMath into template images, so SwiftUI tints them
//  with the surrounding text color (dark mode, quotes). Inline math is placed
//  in a Text on the text baseline; display math is its own block.
//

#if canImport(SwiftMath)
import SwiftMath
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
public enum MathRenderer {
    #if canImport(UIKit)
    public typealias TextStyle = UIFont.TextStyle
    #else
    public typealias TextStyle = NSFont.TextStyle
    #endif

    public struct Rendered {
        public var image: Image
        /// Depth below the baseline, in points.
        public var descent: CGFloat
    }

    private final class Entry {
        let rendered: Rendered?
        init(_ rendered: Rendered?) { self.rendered = rendered }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 500
        return cache
    }()

    /// nil when SwiftMath cannot parse `latex` (unknown command, unbalanced
    /// braces); callers show the source instead.
    public static func render(_ latex: String, fontSize: CGFloat, display: Bool) -> Rendered? {
        let key = "\(display ? "D" : "T")\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.rendered }
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        var rendered: Rendered?
        if error == nil, let image, let layout, image.size.width > 0, let (cgImage, scale) = bitmap(image) {
            rendered = Rendered(
                image: Image(decorative: cgImage, scale: scale).renderingMode(.template),
                descent: layout.descent
            )
        }
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    #if canImport(UIKit)
    private static func bitmap(_ image: UIImage) -> (CGImage, CGFloat)? {
        image.cgImage.map { ($0, image.scale) }
    }

    /// Point size of a Dynamic Type text style at `typeSize`, for math that
    /// sits in text of that style.
    public static func fontSize(_ style: TextStyle, _ typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
    }
    #else
    /// SwiftMath draws on macOS into a resolution-independent NSImage;
    /// rasterize it at 2× so formulas stay sharp on Retina displays.
    private static func bitmap(_ image: NSImage) -> (CGImage, CGFloat)? {
        let scale: CGFloat = 2
        let size = image.size
        guard let context = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { ($0, scale) }
    }

    /// Point size of a text style, for math that sits in text of that style.
    /// macOS has no Dynamic Type, so `typeSize` is not used.
    public static func fontSize(_ style: TextStyle, _ typeSize: DynamicTypeSize) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize
    }
    #endif
}

extension Text {
    /// `text` with its inline math runs (see `MathAttribute`) typeset at
    /// `mathSize` points. A formula SwiftMath cannot parse stays as source.
    /// Inline code gets a tinted background and a slightly smaller
    /// monospaced face: monospaced glyphs look larger than the text around
    /// them. `mathSize` is that text's point size.
    @MainActor
    public init(math source: AttributedString, mathSize: CGFloat) {
        let text = Self.styledCode(source, size: mathSize)
        guard text.runs.contains(where: { $0[MathAttribute.self] != nil }) else {
            self.init(text)
            return
        }
        var result = Text(verbatim: "")
        var pending = AttributedString()
        for run in text.runs {
            guard let latex = run[MathAttribute.self],
                  let rendered = MathRenderer.render(latex, fontSize: mathSize, display: false) else {
                pending.append(text[run.range])
                continue
            }
            let formula = Text(rendered.image).baselineOffset(-rendered.descent).accessibilityLabel(Text(verbatim: latex))
            result = Text("\(result)\(Text(pending))\(formula)")
            pending = AttributedString()
        }
        self = Text("\(result)\(Text(pending))")
    }

    private static var codeBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }

    @MainActor
    static func styledCode(_ text: AttributedString, size: CGFloat) -> AttributedString {
        var styled = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: (size * 0.88).rounded(), design: .monospaced)
            styled[run.range].backgroundColor = codeBackground
        }
        return styled
    }
}
#endif
