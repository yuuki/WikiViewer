//
//  SyntheticVault.swift
//  IndexerCore
//
//  Deterministic synthetic Obsidian vaults for tests and benchmarks.
//  Same spec + seed ⇒ byte-identical vault. Generated on demand; never
//  committed.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WikiShared

public struct SyntheticVaultSpec: Sendable, CustomStringConvertible {
    public var noteCount = 20_000
    public var seed: UInt64 = 42
    public var averageNoteBytes = 2_000
    public var linksPerNote = 6
    public var folderCount = 400
    public var tagCardinality = 500
    /// Fraction of paragraphs written in Japanese.
    public var japaneseRatio = 0.5
    /// Fraction of notes embedding an image.
    public var assetRate = 0.02
    /// Longest side of generated images.
    public var imageSize = 2400
    /// Fraction of notes whose basename duplicates another note's.
    public var duplicateBasenameRate = 0.01
    /// Fraction of links pointing at notes that do not exist.
    public var unresolvedLinkRate = 0.03

    public init() {}

    public var description: String {
        "notes=\(noteCount) seed=\(seed) avgBytes=\(averageNoteBytes) links=\(linksPerNote) folders=\(folderCount) tags=\(tagCardinality) ja=\(japaneseRatio) assets=\(assetRate)"
    }
}

/// SplitMix64: tiny, fast, deterministic across platforms.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func pick<T>(_ array: [T]) -> T { array[int(array.count)] }
}

public enum SyntheticVault {
    /// Marker file: benchmarks refuse to modify a vault without it.
    public static let markerName = ".wikiviewer-synthetic"

    static let englishWords = "system note index memory query folder vault graph link search design cache update stream sqlite swift build viewer reader render markdown heading table image asset tag alias backlink snapshot generation publish manifest review latency budget scale device network battery thread actor task queue storage compact".split(separator: " ").map(String.init)
    static let japaneseWords = ["東京", "設計", "検索", "索引", "記憶", "更新", "表示", "文書", "会議", "読書", "旅行", "料理", "研究", "開発", "性能", "測定", "品質", "安全", "同期", "端末", "画像", "見出し", "日本語", "全文検索", "データベース", "アーキテクチャ", "メモ", "アイデア", "プロジェクト", "議事録"]
    static let japaneseParticles = ["の", "を", "に", "が", "は", "と", "で", "について", "から"]

    /// A directory counts as synthetic only if it carries the marker file AND
    /// its `.obsidian` folder contains nothing but the generated `app.json`
    /// (a real vault has workspace/plugin files there). Destructive commands
    /// (`synth` overwriting, `bench` editing notes) require this.
    public static func isSyntheticVault(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard let marker = try? String(contentsOf: root.appendingPathComponent(markerName), encoding: .utf8),
              marker.hasPrefix("synthetic vault") else { return false }
        let obsidian = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(".obsidian").path)) ?? []
        return obsidian.allSatisfy { $0 == "app.json" }
    }

    public static func generate(spec: SyntheticVaultSpec, at root: URL) throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let contents = try fm.contentsOfDirectory(atPath: root.path)
            guard contents.isEmpty || isSyntheticVault(root) else {
                throw IndexerError.unsafeLocation("\(root.path) is not empty and is not a synthetic vault")
            }
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic vault \(spec)\n".utf8).write(to: root.appendingPathComponent(markerName))
        try fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".obsidian/app.json"))

        var rng = SplitMix64(state: spec.seed)

        // Folder tree: two levels, some Japanese names.
        var folders: [String] = []
        let topCount = max(1, Int(Double(spec.folderCount).squareRoot()))
        for i in 0..<spec.folderCount {
            let top = i % topCount
            let topName = top % 3 == 0 ? "領域 \(top)" : "Area \(top)"
            folders.append(i < topCount ? topName : "\(topName)/Topic \(i)")
        }
        let tags = (0..<max(1, spec.tagCardinality)).map { i in i % 4 == 0 ? "タグ\(i)" : (i % 7 == 0 ? "project/p\(i)" : "tag\(i)") }

        // Note names; a few intentionally duplicated basenames.
        var names: [String] = []
        var paths: [String] = []
        names.reserveCapacity(spec.noteCount)
        for i in 0..<spec.noteCount {
            let name: String
            if i > 10, rng.chance(spec.duplicateBasenameRate) {
                name = names[rng.int(i)]
            } else if i % 3 == 0 {
                name = "メモ \(i) \(rng.pick(japaneseWords))"
            } else {
                name = "Note \(i) \(rng.pick(englishWords))"
            }
            names.append(name)
            paths.append(folders[rng.int(folders.count)] + "/" + name + ".md")
        }

        // Images: a pool smaller than the number of embeds to exercise dedupe.
        let imageNotes = Int(Double(spec.noteCount) * spec.assetRate)
        let imagePoolSize = max(0, Int(Double(imageNotes) * 0.8))
        var imagePaths: [String] = []
        if imagePoolSize > 0 {
            try fm.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
            let template = try makeImage(size: spec.imageSize, seed: spec.seed)
            for i in 0..<imagePoolSize {
                let path = "attachments/image-\(i).jpg"
                // Every fifth image is a byte-identical duplicate of the template → content dedupe.
                let data = i % 5 == 0 ? template : try makeImage(size: spec.imageSize, seed: spec.seed &+ UInt64(i))
                try data.write(to: root.appendingPathComponent(path))
                imagePaths.append(path)
            }
        }

        var totalBytes = 0
        for i in 0..<spec.noteCount {
            var text = ""
            text.reserveCapacity(spec.averageNoteBytes + 512)
            // Frontmatter on most notes.
            if i % 4 != 3 {
                text += "---\n"
                text += "created: 2026-0\(1 + i % 9)-1\(i % 10)\n"
                text += "tags: [\(tags[rng.int(tags.count)]), \(tags[rng.int(tags.count)])]\n"
                if i % 10 == 0 { text += "aliases: [\"alias-\(i)\", \"別名\(i)\"]\n" }
                text += "---\n"
            }
            text += "# \(names[i])\n\n"
            let target = max(200, spec.averageNoteBytes / 2 + rng.int(spec.averageNoteBytes))
            var section = 0
            var linksLeft = spec.linksPerNote
            while text.utf8.count < target {
                if rng.int(5) == 0 {
                    section += 1
                    text += "\n## Section \(section) \(rng.pick(japaneseWords))\n\n"
                }
                var paragraph = rng.chance(spec.japaneseRatio) ? japaneseSentence(&rng) : englishSentence(&rng)
                if linksLeft > 0, rng.int(2) == 0 {
                    paragraph += " " + makeLink(&rng, names: names, paths: paths, from: i, spec: spec)
                    linksLeft -= 1
                }
                if rng.int(8) == 0 { paragraph += " #\(tags[rng.int(tags.count)])" }
                if rng.int(12) == 0 { paragraph += " ^b\(section)x\(rng.int(1000))" }
                text += paragraph + "\n\n"
            }
            while linksLeft > 0 {
                text += "- " + makeLink(&rng, names: names, paths: paths, from: i, spec: spec) + "\n"
                linksLeft -= 1
            }
            if !imagePaths.isEmpty, Double(i % 1000) / 1000 < spec.assetRate {
                text += "\n![[\(VaultPath.fileName(of: imagePaths[rng.int(imagePaths.count)]))]]\n"
            }
            if i % 50 == 0 {
                text += "\n```swift\nlet ignored = \"[[not a link]] #notatag\"\n```\n"
            }
            let url = root.appendingPathComponent(paths[i])
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            totalBytes += data.count
            // Deterministic content; mtimes are whatever the file system assigns.
            try data.write(to: url)
        }
        return "\(spec.noteCount) notes (\(totalBytes / 1024) KiB), \(imagePaths.count) images, \(folders.count) folders at \(root.path)"
    }

    static func makeLink(_ rng: inout SplitMix64, names: [String], paths: [String], from i: Int, spec: SyntheticVaultSpec) -> String {
        if rng.chance(spec.unresolvedLinkRate) {
            return "[[Missing note \(rng.int(10_000))]]"
        }
        let j = rng.int(names.count)
        switch rng.int(10) {
        case 0: return "[[\(names[j])|表示 \(j)]]"
        case 1: return "[[\(names[j])#Section 1 \(japaneseWords[0])]]"
        case 2:
            let p = paths[j]
            return "[[\(String(p.dropLast(3)))]]"
        case 3:
            let encoded = paths[j].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? paths[j]
            return "[link](/\(encoded))"
        default: return "[[\(names[j])]]"
        }
    }

    static func englishSentence(_ rng: inout SplitMix64) -> String {
        let count = 8 + rng.int(14)
        var words: [String] = []
        for _ in 0..<count { words.append(rng.pick(englishWords)) }
        var s = words.joined(separator: " ")
        s = s.prefix(1).uppercased() + s.dropFirst() + "."
        return s
    }

    static func japaneseSentence(_ rng: inout SplitMix64) -> String {
        let count = 4 + rng.int(8)
        var s = ""
        for _ in 0..<count {
            s += rng.pick(japaneseWords) + rng.pick(japaneseParticles)
        }
        return s + "。"
    }

    static func makeImage(size: Int, seed: UInt64) throws -> Data {
        let width = size
        let height = size * 2 / 3
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw IndexerError.publicationFailed("CGContext")
        }
        var rng = SplitMix64(state: seed)
        for _ in 0..<12 {
            ctx.setFillColor(red: CGFloat(rng.int(255)) / 255, green: CGFloat(rng.int(255)) / 255, blue: CGFloat(rng.int(255)) / 255, alpha: 1)
            ctx.fill(CGRect(x: rng.int(width), y: rng.int(height), width: 1 + rng.int(width / 2), height: 1 + rng.int(height / 2)))
        }
        guard let image = ctx.makeImage() else { throw IndexerError.publicationFailed("makeImage") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IndexerError.publicationFailed("CGImageDestination")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw IndexerError.publicationFailed("finalize") }
        return out as Data
    }
}
