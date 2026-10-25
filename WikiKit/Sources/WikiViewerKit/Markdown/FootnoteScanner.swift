//
//  FootnoteScanner.swift
//  WikiViewerKit
//
//  Finds Markdown footnotes in a note body: references `[^label]` in the
//  text and definitions `[^label]: text` at the start of a line. Fenced code
//  blocks and code spans are skipped. Only the viewer needs this; the
//  indexer never looks at footnotes.
//
//  Like Obsidian (markdown-it-footnote), a reference only counts when its
//  label has a definition, and a definition starts a line indented by at
//  most three spaces, outside blockquotes and lists.
//

import Foundation

struct ScannedFootnotes: Equatable {
    struct Reference: Equatable {
        /// Byte range of `[^label]`.
        var range: Range<Int>
        var label: String
        var line: Int
    }

    struct Definition: Equatable {
        /// Byte range of `[^label]:` and the spaces after it.
        var range: Range<Int>
        var label: String
        var line: Int
        /// Byte offset of the end of the definition's first line.
        var lineEnd: Int
    }

    var references: [Reference] = []
    var definitions: [Definition] = []
}

struct FootnoteScanner {
    private static let backslash = UInt8(ascii: "\\")
    private static let backtick = UInt8(ascii: "`")
    private static let tilde = UInt8(ascii: "~")
    private static let open = UInt8(ascii: "[")
    private static let close = UInt8(ascii: "]")
    private static let caret = UInt8(ascii: "^")
    private static let colon = UInt8(ascii: ":")
    private static let paren = UInt8(ascii: "(")

    func scan(_ body: String) -> ScannedFootnotes {
        let bytes = Array(body.utf8)
        // Only scan notes that can contain a footnote at all.
        guard body.contains("[^") else { return ScannedFootnotes() }
        var lines: [Range<Int>] = []
        var start = 0
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") {
            lines.append(start..<i)
            start = i + 1
        }
        lines.append(start..<bytes.count)

        var references: [ScannedFootnotes.Reference] = []
        var definitions: [ScannedFootnotes.Definition] = []
        var fence: (marker: UInt8, count: Int)?
        for (index, line) in lines.enumerated() {
            let end = line.upperBound > line.lowerBound && bytes[line.upperBound - 1] == UInt8(ascii: "\r") ? line.upperBound - 1 : line.upperBound
            let lead = containerEnd(bytes, line.lowerBound, end)
            if let open = fence {
                if isFenceClose(bytes, lead, end, open) { fence = nil }
                continue
            }
            if let open = fenceOpen(bytes, lead, end) {
                fence = open
                continue
            }
            var from = line.lowerBound
            if let definition = definition(bytes, line.lowerBound, end, line: index) {
                definitions.append(definition)
                from = definition.range.upperBound
            }
            references += self.references(bytes, from, end, line: index)
        }
        let defined = Set(definitions.map(\.label))
        return ScannedFootnotes(references: references.filter { defined.contains($0.label) }, definitions: definitions)
    }

    /// `[^label]:` at the start of the line, after at most three spaces.
    private func definition(_ bytes: [UInt8], _ start: Int, _ end: Int, line: Int) -> ScannedFootnotes.Definition? {
        var p = start
        while p < end, p - start < 3, bytes[p] == UInt8(ascii: " ") { p += 1 }
        guard let label = label(bytes, at: p, end), label.end < end, bytes[label.end] == Self.colon else { return nil }
        var q = label.end + 1
        while q < end, isSpace(bytes[q]) { q += 1 }
        return ScannedFootnotes.Definition(range: p..<q, label: label.text, line: line, lineEnd: end)
    }

    private func references(_ bytes: [UInt8], _ start: Int, _ end: Int, line: Int) -> [ScannedFootnotes.Reference] {
        var result: [ScannedFootnotes.Reference] = []
        var j = start
        while j < end {
            switch bytes[j] {
            case Self.backslash:
                j += 2
            case Self.backtick:
                var k = j
                while k < end, bytes[k] == Self.backtick { k += 1 }
                j = closingBacktickRun(bytes, length: k - j, from: k, to: end).map { $0 + (k - j) } ?? k
            case Self.open:
                // "[^x](url)" is a Markdown link whose text is "^x".
                if let label = label(bytes, at: j, end), label.end == end || bytes[label.end] != Self.paren {
                    result.append(ScannedFootnotes.Reference(range: j..<label.end, label: label.text, line: line))
                    j = label.end
                } else {
                    j += 1
                }
            default:
                j += 1
            }
        }
        return result
    }

    /// `[^label]` at `p`: the label, and the offset after the `]`. Labels
    /// have no whitespace or brackets.
    private func label(_ bytes: [UInt8], at p: Int, _ end: Int) -> (text: String, end: Int)? {
        guard p + 2 < end, bytes[p] == Self.open, bytes[p + 1] == Self.caret else { return nil }
        var q = p + 2
        while q < end, bytes[q] != Self.close {
            if isSpace(bytes[q]) || bytes[q] == Self.open || bytes[q] == Self.backslash { return nil }
            q += 1
        }
        guard q < end, q > p + 2 else { return nil }
        return (String(decoding: bytes[(p + 2)..<q], as: UTF8.self), q + 1)
    }

    // MARK: Utilities

    private func isSpace(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t")
    }

    /// Skips indentation and blockquote markers.
    private func containerEnd(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int {
        var p = start
        while p < end, isSpace(bytes[p]) || bytes[p] == UInt8(ascii: ">") { p += 1 }
        return p
    }

    private func fenceOpen(_ bytes: [UInt8], _ p: Int, _ end: Int) -> (marker: UInt8, count: Int)? {
        guard p < end, bytes[p] == Self.backtick || bytes[p] == Self.tilde else { return nil }
        let marker = bytes[p]
        var q = p
        while q < end, bytes[q] == marker { q += 1 }
        guard q - p >= 3 else { return nil }
        if marker == Self.backtick, bytes[q..<end].contains(Self.backtick) { return nil }
        return (marker, q - p)
    }

    private func isFenceClose(_ bytes: [UInt8], _ p: Int, _ end: Int, _ fence: (marker: UInt8, count: Int)) -> Bool {
        var q = p
        while q < end, bytes[q] == fence.marker { q += 1 }
        return q - p >= fence.count && bytes[q..<end].allSatisfy(isSpace)
    }

    private func closingBacktickRun(_ bytes: [UInt8], length: Int, from start: Int, to end: Int) -> Int? {
        var k = start
        while k < end {
            guard bytes[k] == Self.backtick else { k += 1; continue }
            var m = k
            while m < end, bytes[m] == Self.backtick { m += 1 }
            if m - k == length { return k }
            k = m
        }
        return nil
    }
}
