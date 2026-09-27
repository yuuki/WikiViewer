//
//  MathScanner.swift
//  WikiViewerKit
//
//  Finds Obsidian LaTeX math in a note body: `$$ … $$` display math (on its
//  own lines or within a line) and `$ … $` inline math. Code blocks and code
//  spans are skipped. Only the viewer needs this; the indexer never looks
//  inside math.
//
//  Inline math follows Obsidian (and Pandoc): the opening `$` is not followed
//  by whitespace, the closing `$` is not preceded by whitespace and not
//  followed by a digit, so "$5 and $6" stays text. Both delimiters are on the
//  same line, and `\$` is a literal dollar.
//

import Foundation

struct ScannedMath: Equatable {
    /// Byte range of the whole construct, delimiters included.
    var range: Range<Int>
    var latex: String
    var display: Bool
    /// For display math spanning lines: the container prefix ("> ",
    /// indentation) of every line after the first, in order. The rewritten
    /// text keeps them so line numbers and blockquotes stay intact.
    var linePrefixes: [String] = []
}

struct MathScanner {
    private static let dollar = UInt8(ascii: "$")
    private static let backslash = UInt8(ascii: "\\")
    private static let backtick = UInt8(ascii: "`")
    private static let tilde = UInt8(ascii: "~")

    func scan(_ body: String) -> [ScannedMath] {
        let bytes = Array(body.utf8)
        // Only scan notes that can contain math at all.
        guard bytes.contains(Self.dollar) else { return [] }
        var lines: [Range<Int>] = []
        var start = 0
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") {
            lines.append(start..<i)
            start = i + 1
        }
        lines.append(start..<bytes.count)

        var result: [ScannedMath] = []
        var fence: (marker: UInt8, count: Int)?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let contentEnd = line.upperBound > line.lowerBound && bytes[line.upperBound - 1] == UInt8(ascii: "\r") ? line.upperBound - 1 : line.upperBound
            let lead = containerEnd(bytes, line.lowerBound, contentEnd)
            if let open = fence {
                if isFenceClose(bytes, lead, contentEnd, open) { fence = nil }
                index += 1
                continue
            }
            if let open = fenceOpen(bytes, lead, contentEnd) {
                fence = open
                index += 1
                continue
            }
            if let block = displayBlock(bytes, lines: lines, at: index, lead: lead) {
                result.append(block.math)
                index = block.nextLine
                continue
            }
            result += inlineMath(bytes, lead, contentEnd)
            index += 1
        }
        return result
    }

    /// A `$$` block starting at the beginning of line `index`, up to the
    /// line ending in `$$`. Unclosed blocks are not math.
    private func displayBlock(_ bytes: [UInt8], lines: [Range<Int>], at index: Int, lead: Int) -> (math: ScannedMath, nextLine: Int)? {
        let first = lines[index]
        guard lead + 1 < first.upperBound, bytes[lead] == Self.dollar, bytes[lead + 1] == Self.dollar else { return nil }
        let firstEnd = trimmedEnd(bytes, lead, first.upperBound)
        // "$$ x $$" on one line.
        if firstEnd - lead > 4, bytes[firstEnd - 1] == Self.dollar, bytes[firstEnd - 2] == Self.dollar {
            // Leave "$$a$$ and $$b$$" to the inline pass.
            guard !contains(bytes, lead + 2, firstEnd - 2, Self.dollar, Self.dollar) else { return nil }
            let latex = text(bytes, lead + 2, firstEnd - 2)
            return (ScannedMath(range: lead..<firstEnd, latex: latex, display: true), index + 1)
        }
        guard firstEnd - lead == 2 || !contains(bytes, lead + 2, firstEnd, Self.dollar, Self.dollar) else { return nil }
        var parts = [text(bytes, lead + 2, firstEnd)]
        var prefixes: [String] = []
        var k = index + 1
        while k < lines.count {
            let line = lines[k]
            let end = trimmedEnd(bytes, line.lowerBound, line.upperBound)
            let contentStart = containerEnd(bytes, line.lowerBound, end)
            prefixes.append(text(bytes, line.lowerBound, contentStart))
            if end - contentStart >= 2, bytes[end - 1] == Self.dollar, bytes[end - 2] == Self.dollar {
                parts.append(text(bytes, contentStart, end - 2))
                let latex = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (ScannedMath(range: lead..<end, latex: latex, display: true, linePrefixes: prefixes), k + 1)
            }
            parts.append(text(bytes, contentStart, end))
            k += 1
        }
        return nil
    }

    private func inlineMath(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [ScannedMath] {
        var result: [ScannedMath] = []
        var j = start
        while j < end {
            switch bytes[j] {
            case Self.backslash:
                j += 2
            case Self.backtick:
                var k = j
                while k < end, bytes[k] == Self.backtick { k += 1 }
                j = closingBacktickRun(bytes, length: k - j, from: k, to: end).map { $0 + (k - j) } ?? k
            case Self.dollar:
                if j + 1 < end, bytes[j + 1] == Self.dollar {
                    // $$…$$ within a line is display math.
                    if let close = find(bytes, from: j + 2, to: end, where: { k in bytes[k] == Self.dollar && k + 1 < end && bytes[k + 1] == Self.dollar }),
                       close > j + 2 {
                        let latex = text(bytes, j + 2, close).trimmingCharacters(in: .whitespaces)
                        result.append(ScannedMath(range: j..<(close + 2), latex: latex, display: true))
                        j = close + 2
                    } else {
                        j += 2
                    }
                } else if let close = inlineClose(bytes, open: j, end: end) {
                    result.append(ScannedMath(range: j..<(close + 1), latex: text(bytes, j + 1, close), display: false))
                    j = close + 1
                } else {
                    j += 1
                }
            default:
                j += 1
            }
        }
        return result
    }

    private func inlineClose(_ bytes: [UInt8], open: Int, end: Int) -> Int? {
        guard open + 1 < end, !isSpace(bytes[open + 1]) else { return nil }
        var k = open + 1
        while k < end {
            let b = bytes[k]
            if b == Self.backslash { k += 2; continue }
            if b == Self.dollar {
                let followedByDigit = k + 1 < end && bytes[k + 1] >= 0x30 && bytes[k + 1] <= 0x39
                if !isSpace(bytes[k - 1]), !followedByDigit, k > open + 1 { return k }
                return nil
            }
            k += 1
        }
        return nil
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

    private func trimmedEnd(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int {
        var e = end
        while e > start, isSpace(bytes[e - 1]) || bytes[e - 1] == UInt8(ascii: "\r") { e -= 1 }
        return e
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

    private func find(_ bytes: [UInt8], from start: Int, to end: Int, where match: (Int) -> Bool) -> Int? {
        var k = start
        while k < end {
            if bytes[k] == Self.backslash { k += 2; continue }
            if match(k) { return k }
            k += 1
        }
        return nil
    }

    private func contains(_ bytes: [UInt8], _ start: Int, _ end: Int, _ a: UInt8, _ b: UInt8) -> Bool {
        find(bytes, from: start, to: end) { k in bytes[k] == a && k + 1 < end && bytes[k + 1] == b } != nil
    }

    private func text(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<max(start, end)], as: UTF8.self)
    }
}
