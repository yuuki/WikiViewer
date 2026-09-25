// Generates the fixture vault's images deterministically.
// Usage: swift scripts/make_fixture_images.swift Fixtures/vault/attachments
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func draw(width: Int, height: Int, alpha: Bool) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    if !alpha {
        ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.6, 0.3), (0.2, 0.3, 0.8), (0.9, 0.7, 0.1)]
    for (i, c) in colors.enumerated() {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        let w = width / 5, h = height / 3
        ctx.fill(CGRect(x: w * i + w / 2, y: h / 2 + (i % 2) * h, width: w, height: h))
    }
    // An "up" arrow so orientation handling is visible.
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.move(to: CGPoint(x: width / 2, y: height - 10))
    ctx.addLine(to: CGPoint(x: width / 2 - width / 10, y: height - height / 4))
    ctx.addLine(to: CGPoint(x: width / 2 + width / 10, y: height - height / 4))
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
write(draw(width: 400, height: 300, alpha: true), to: dir.appendingPathComponent("diagram.png"), type: .png)
try FileManager.default.copyItem(at: dir.appendingPathComponent("diagram.png"), to: dir.appendingPathComponent("copy of diagram.png"))
// Large photo stored rotated with EXIF orientation 6 (display = 2000x3000).
write(draw(width: 3000, height: 2000, alpha: false), to: dir.appendingPathComponent("photo.jpg"), type: .jpeg,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.6, kCGImagePropertyOrientation: 6])
print("ok")
