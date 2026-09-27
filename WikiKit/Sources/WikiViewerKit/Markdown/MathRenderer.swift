//
//  MathRenderer.swift
//  WikiViewerKit
//
//  Typesets LaTeX with SwiftMath into template images, so SwiftUI tints them
//  with the surrounding text color (dark mode, quotes). Inline math is placed
//  in a Text on the text baseline; display math is its own block.
//

#if canImport(UIKit)
import SwiftMath
import SwiftUI
import UIKit

@MainActor
public enum MathRenderer {
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
        if error == nil, let image, let cgImage = image.cgImage, let layout, image.size.width > 0 {
            rendered = Rendered(
                image: Image(decorative: cgImage, scale: image.scale).renderingMode(.template),
                descent: layout.descent
            )
        }
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }

    /// Point size of a Dynamic Type text style at `typeSize`, for math that
    /// sits in text of that style.
    public static func fontSize(_ style: UIFont.TextStyle, _ typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
    }
}

extension Text {
    /// `text` with its inline math runs (see `MathAttribute`) typeset at
    /// `mathSize` points. A formula SwiftMath cannot parse stays as source.
    @MainActor
    public init(math text: AttributedString, mathSize: CGFloat) {
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
}
#endif
