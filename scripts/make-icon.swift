// Renders the app icon into WikiViewer/Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/make-icon.swift
//
// The mark is a "W" drawn as a graph: five notes joined by four links, the
// middle one lit as the note being read, sitting in a faint larger graph on
// engineering-paper dots. It stands for a wiki of linked notes and for the
// graph view researchers use to navigate one.
//
// iOS gets the full-bleed 1024 px square in light, dark and tinted
// appearances (the system applies the mask). macOS gets the classic
// rounded-rect template with margins and a shadow at every size.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "WikiViewer/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

struct Palette {
    var bgTop: CGColor, bgBottom: CGColor
    var dots: CGColor
    var faint: CGColor, faintAlpha: CGFloat
    var edge: CGColor, node: CGColor
    var accent: CGColor, glow: CGColor
}

let light = Palette(
    bgTop: rgb(0x23426B), bgBottom: rgb(0x0C1830),
    dots: rgb(0xFFFFFF, 0.08),
    faint: rgb(0x9FB8D9), faintAlpha: 0.28,
    edge: rgb(0xF3EAD7), node: rgb(0xF3EAD7),
    accent: rgb(0xFFB547), glow: rgb(0xFFB547, 0.55))

let dark = Palette(
    bgTop: rgb(0x151B24), bgBottom: rgb(0x07090D),
    dots: rgb(0xFFFFFF, 0.06),
    faint: rgb(0x7F95B3), faintAlpha: 0.26,
    edge: rgb(0xE8E0CE), node: rgb(0xE8E0CE),
    accent: rgb(0xFFB547), glow: rgb(0xFFB547, 0.45))

// Tinted icons are grayscale; the system recolors them by luminance.
let tinted = Palette(
    bgTop: rgb(0x000000), bgBottom: rgb(0x000000),
    dots: rgb(0xFFFFFF, 0.07),
    faint: rgb(0xFFFFFF), faintAlpha: 0.26,
    edge: rgb(0xD9D9D9), node: rgb(0xD9D9D9),
    accent: rgb(0xFFFFFF), glow: rgb(0xFFFFFF, 0.35))

// Design space is 1024 x 1024 with y pointing down.
let w: [CGPoint] = [
    CGPoint(x: 226, y: 350), CGPoint(x: 369, y: 700), CGPoint(x: 512, y: 440),
    CGPoint(x: 655, y: 700), CGPoint(x: 798, y: 350),
]
let lit = 2
let faint: [(CGPoint, Int)] = [ // faint node, and the W node it links to
    (CGPoint(x: 512, y: 190), 2),
    (CGPoint(x: 150, y: 840), 1),
    (CGPoint(x: 880, y: 830), 3),
    (CGPoint(x: 110, y: 170), 0),
]

func drawArt(_ c: CGContext, _ p: Palette) {
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [p.bgTop, p.bgBottom] as CFArray,
                              locations: [0, 1])!
    c.saveGState()
    c.clip(to: full)
    c.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 0),
                         end: CGPoint(x: 824, y: 1024),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    c.setFillColor(p.dots)
    for gx in stride(from: 32.0, to: 1024, by: 64) {
        for gy in stride(from: 32.0, to: 1024, by: 64) {
            c.fillEllipse(in: CGRect(x: gx - 3.5, y: gy - 3.5, width: 7, height: 7))
        }
    }

    c.setLineCap(.round)
    c.setLineJoin(.round)

    // One transparency layer, so links and nodes do not darken where they overlap.
    c.saveGState()
    c.setAlpha(p.faintAlpha)
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setStrokeColor(p.faint)
    c.setLineWidth(12)
    for (pt, to) in faint {
        c.move(to: pt)
        c.addLine(to: w[to])
    }
    c.strokePath()
    c.setFillColor(p.faint)
    for (pt, _) in faint {
        c.fillEllipse(in: CGRect(x: pt.x - 26, y: pt.y - 26, width: 52, height: 52))
    }
    c.endTransparencyLayer()
    c.restoreGState()

    c.setStrokeColor(p.edge)
    c.setLineWidth(38)
    c.addLines(between: w)
    c.strokePath()

    for (i, pt) in w.enumerated() where i != lit {
        c.setFillColor(p.node)
        c.fillEllipse(in: CGRect(x: pt.x - 60, y: pt.y - 60, width: 120, height: 120))
    }

    let hub = w[lit]
    c.saveGState()
    c.setShadow(offset: .zero, blur: 70, color: p.glow)
    c.setFillColor(p.accent)
    c.fillEllipse(in: CGRect(x: hub.x - 76, y: hub.y - 76, width: 152, height: 152))
    c.restoreGState()
    // A ring cut into the lit node, like a selected vertex in a graph editor.
    c.setStrokeColor(p.bgBottom)
    c.setLineWidth(14)
    c.strokeEllipse(in: CGRect(x: hub.x - 44, y: hub.y - 44, width: 88, height: 88))
}

func render(size: Int, mac: Bool, palette: Palette) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue
                                      : CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    // Flip to y-down design space.
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: s, y: -s)

    if mac {
        // macOS icon template: 824 pt body, 100 pt margins, continuous corners.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0.35))
        c.addPath(shape)
        c.setFillColor(palette.bgBottom)
        c.fillPath()
        c.restoreGState()
        c.addPath(shape)
        c.clip()
        c.translateBy(x: 100, y: 100)
        c.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }
    drawArt(c, palette)
    return c.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(url.path)") }
    print(url.path)
}

write(render(size: 1024, mac: false, palette: light), "AppIcon.png")
write(render(size: 1024, mac: false, palette: dark), "AppIcon-Dark.png")
write(render(size: 1024, mac: false, palette: tinted), "AppIcon-Tinted.png")
for px in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(size: px, mac: true, palette: light), "AppIcon-mac-\(px).png")
}
