//
//  ObsidianScanner.swift
//  WikiShared
//

/// A code-aware, single-pass scanner for the Obsidian-specific parts of a
/// note body: wikilinks, embeds, internal Markdown links, inline tags,
/// headings, block IDs and comments.
///
/// The same scanner runs in the indexer (to populate the `links`, `tags`,
/// `headings` and `blocks` tables) and in the viewer (to turn the tokens of
/// the displayed note into explicit Markdown nodes before handing the text to
/// swift-markdown). Because both sides use the same code, the ordinal of a
/// link in `ScannedDocument.links` matches `links.ordinal` in the database.
///
/// The scanner works on UTF-8 bytes and reports byte ranges into the body.
/// It skips fenced code blocks, `$$` math blocks, inline code spans, Obsidian
/// `%%comments%%` and HTML comments.
///
/// Known simplifications (documented in ARCHITECTURE.md):
/// - indented (4-space) code blocks are scanned like ordinary text;
/// - inline code spans must open and close on the same line;
/// - inline `$math$` is not skipped.
public struct ObsidianScanner: Sendable {
    public init() {}

    public func scan(_ body: String) -> ScannedDocument {
        var bytes = Array(body.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            var state = ScanState(bytes: UnsafeBufferPointer(buffer))
            state.run()
            return state.document
        }
    }
}

public struct ScannedDocument: Sendable, Equatable {
    public var links: [ScannedLink] = []
    public var tags: [ScannedTag] = []
    public var headings: [ScannedHeading] = []
    public var blockIDs: [ScannedBlockID] = []
    /// Byte ranges that Obsidian hides in reading view (comments).
    public var hiddenRanges: [Range<Int>] = []

    public init() {}
}

public struct ScannedLink: Sendable, Equatable {
    public enum Kind: Int, Sendable {
        case wiki = 0
        case markdown = 1
    }

    public var kind: Kind
    public var isEmbed: Bool
    /// Wikilinks: the inner text between the brackets. Markdown links: the
    /// destination as written.
    public var raw: String
    /// Markdown links only: the link text / image alt text.
    public var text: String?
    public var target: LinkTarget
    /// Byte range of the whole token, e.g. `![[a.png|300]]` or `[x](y.md)`.
    public var range: Range<Int>
    /// Zero-based line number in the body.
    public var line: Int
}

public struct ScannedTag: Sendable, Equatable {
    /// Tag name without the leading "#".
    public var name: String
    public var range: Range<Int>
    public var line: Int
}

public struct ScannedHeading: Sendable, Equatable {
    public var level: Int
    public var text: String
    public var line: Int
}

public struct ScannedBlockID: Sendable, Equatable {
    public var id: String
    /// Range covering the marker including the whitespace before "^".
    public var range: Range<Int>
    public var line: Int
}

private enum Byte {
    static let newline = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let backslash = UInt8(ascii: "\\")
    static let backtick = UInt8(ascii: "`")
    static let tilde = UInt8(ascii: "~")
    static let bang = UInt8(ascii: "!")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let hash = UInt8(ascii: "#")
    static let percent = UInt8(ascii: "%")
    static let caret = UInt8(ascii: "^")
    static let lt = UInt8(ascii: "<")
    static let gt = UInt8(ascii: ">")
    static let dollar = UInt8(ascii: "$")
    static let dash = UInt8(ascii: "-")
    static let equals = UInt8(ascii: "=")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let pipe = UInt8(ascii: "|")
}

private struct ScanState {
    let bytes: UnsafeBufferPointer<UInt8>
    var document = ScannedDocument()

    enum BlockMode {
        case normal
        case fence(marker: UInt8, count: Int, quoted: Bool)
        case math
        case percentComment(start: Int)
        case htmlComment(start: Int)
    }

    var mode: BlockMode = .normal
    /// Previous line was a paragraph line that could become a setext heading.
    var previousParagraph: (start: Int, end: Int, line: Int)?
    /// Inside a list (until a blank line): lines are list content, and a
    /// following "---" is a thematic break, not a setext underline.
    var inList = false
    /// For the current line: matching "]" for each "[" (see scanInline).
    var bracketMatches: [Int: Int] = [:]

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func run() {
        var start = 0
        var line = 0
        let count = bytes.count
        while start <= count {
            var end = start
            while end < count, bytes[end] != Byte.newline { end += 1 }
            var contentEnd = end
            if contentEnd > start, bytes[contentEnd - 1] == Byte.cr { contentEnd -= 1 }
            processLine(start: start, end: contentEnd, line: line)
            if end >= count { break }
            start = end + 1
            line += 1
        }
        switch mode {
        case .percentComment(let s), .htmlComment(let s):
            document.hiddenRanges.append(s..<count)
        default:
            break
        }
    }

    // MARK: Lines

    mutating func processLine(start: Int, end: Int, line: Int) {
        switch mode {
        case .fence(let marker, let count, let quoted):
            if quoted && !hasQuotePrefix(start, end) {
                // A fence opened inside a blockquote/callout ends with it
                // (CommonMark); this line is ordinary content again.
                mode = .normal
            } else {
                if isFenceClose(start: start, end: end, marker: marker, count: count) {
                    mode = .normal
                }
                previousParagraph = nil
                return
            }
        case .math:
            if trimmed(start, end).elementsEqual("$$".utf8) || endsWithDoubleDollar(start, end) {
                mode = .normal
            }
            previousParagraph = nil
            return
        case .percentComment(let commentStart):
            if let close = find(Byte.percent, Byte.percent, from: start, to: end) {
                document.hiddenRanges.append(commentStart..<(close + 2))
                mode = .normal
                let hiddenBefore = document.hiddenRanges.count - 1
                scanInline(from: close + 2, to: end, line: line)
                checkBlockID(start: start, end: end, line: line, hiddenFrom: hiddenBefore)
            }
            previousParagraph = nil
            return
        case .htmlComment(let commentStart):
            if let close = findSequence(Array("-->".utf8), from: start, to: end) {
                document.hiddenRanges.append(commentStart..<(close + 3))
                mode = .normal
                scanInline(from: close + 3, to: end, line: line)
            }
            previousParagraph = nil
            return
        case .normal:
            break
        }

        let lead = skipContainerPrefix(start, end)
        let quoted = hasQuotePrefix(start, end)
        if let (marker, count) = fenceOpen(at: lead, end: end) {
            mode = .fence(marker: marker, count: count, quoted: quoted)
            previousParagraph = nil
            return
        }
        if trimmed(lead, end).starts(with: "$$".utf8) {
            let t = trimmed(lead, end)
            // "$$ x $$" on one line is a complete block.
            if !(t.count > 4 && endsWithDoubleDollar(lead, end)) {
                mode = .math
            }
            previousParagraph = nil
            return
        }

        if lead == end {
            previousParagraph = nil
            inList = false
            return
        }

        // Setext heading underline: "===" or "---" directly under a plain
        // (non-list, non-quote) paragraph line.
        if !quoted, let paragraph = previousParagraph, let level = setextLevel(lead, end) {
            let text = string(trimmedRange(paragraph.start, paragraph.end))
            document.headings.append(ScannedHeading(level: level, text: text, line: paragraph.line))
            previousParagraph = nil
            return
        }

        // ATX heading.
        var inlineStart = lead
        var isHeading = false
        var hashes = 0
        var p = lead
        while p < end, bytes[p] == Byte.hash, hashes < 7 {
            hashes += 1
            p += 1
        }
        if hashes >= 1, hashes <= 6, p == end || bytes[p] == Byte.space || bytes[p] == Byte.tab {
            isHeading = true
            let textRange = headingTextRange(from: p, to: end)
            document.headings.append(ScannedHeading(level: hashes, text: string(textRange), line: line))
            inlineStart = p
        }

        let hiddenBefore = document.hiddenRanges.count
        scanInline(from: inlineStart, to: end, line: line)
        checkBlockID(start: start, end: end, line: line, hiddenFrom: hiddenBefore)

        if isListItem(lead, end) { inList = true }
        if isHeading || quoted || inList || isThematicBreakOrListLike(lead, end) {
            previousParagraph = nil
        } else {
            previousParagraph = (lead, end, line)
        }
    }

    func hasQuotePrefix(_ start: Int, _ end: Int) -> Bool {
        var p = start
        while p < end, bytes[p] == Byte.space || bytes[p] == Byte.tab { p += 1 }
        return p < end && bytes[p] == Byte.gt
    }

    /// "- x", "* x", "+ x", "1. x", "1) x".
    func isListItem(_ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        let b = bytes[start]
        if b == Byte.dash || b == UInt8(ascii: "*") || b == UInt8(ascii: "+") {
            return start + 1 < end && (bytes[start + 1] == Byte.space || bytes[start + 1] == Byte.tab)
        }
        var p = start
        while p < end, p - start < 9, bytes[p] >= 0x30 && bytes[p] <= 0x39 { p += 1 }
        guard p > start, p + 1 < end else { return false }
        return (bytes[p] == UInt8(ascii: ".") || bytes[p] == Byte.closeParen) && (bytes[p + 1] == Byte.space || bytes[p + 1] == Byte.tab)
    }

    /// Skips indentation and blockquote markers so fences and headings inside
    /// callouts/blockquotes are recognized.
    func skipContainerPrefix(_ start: Int, _ end: Int) -> Int {
        var p = start
        while p < end {
            let b = bytes[p]
            if b == Byte.space || b == Byte.tab || b == Byte.gt {
                p += 1
            } else {
                break
            }
        }
        return p
    }

    func fenceOpen(at p: Int, end: Int) -> (UInt8, Int)? {
        guard p < end else { return nil }
        let marker = bytes[p]
        guard marker == Byte.backtick || marker == Byte.tilde else { return nil }
        var q = p
        while q < end, bytes[q] == marker { q += 1 }
        let count = q - p
        guard count >= 3 else { return nil }
        if marker == Byte.backtick {
            // Backtick fence info strings may not contain backticks.
            var r = q
            while r < end {
                if bytes[r] == Byte.backtick { return nil }
                r += 1
            }
        }
        return (marker, count)
    }

    func isFenceClose(start: Int, end: Int, marker: UInt8, count: Int) -> Bool {
        let p = skipContainerPrefix(start, end)
        var q = p
        while q < end, bytes[q] == marker { q += 1 }
        guard q - p >= count else { return false }
        while q < end {
            if bytes[q] != Byte.space && bytes[q] != Byte.tab { return false }
            q += 1
        }
        return true
    }

    func setextLevel(_ start: Int, _ end: Int) -> Int? {
        let t = trimmedRange(start, end)
        guard !t.isEmpty else { return nil }
        let first = bytes[t.lowerBound]
        guard first == Byte.equals || first == Byte.dash else { return nil }
        for i in t where bytes[i] != first { return nil }
        if first == Byte.dash && t.count < 2 { return nil }
        return first == Byte.equals ? 1 : 2
    }

    func isThematicBreakOrListLike(_ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        let b = bytes[start]
        if b == Byte.dash || b == UInt8(ascii: "*") || b == UInt8(ascii: "+") {
            return start + 1 >= end || bytes[start + 1] == Byte.space || bytes[start + 1] == b
        }
        return false
    }

    func headingTextRange(from p: Int, to end: Int) -> Range<Int> {
        var r = trimmedRange(p, end)
        // Strip an optional closing sequence of #'s preceded by a space.
        var q = r.upperBound
        while q > r.lowerBound, bytes[q - 1] == Byte.hash { q -= 1 }
        if q < r.upperBound, q == r.lowerBound || bytes[q - 1] == Byte.space || bytes[q - 1] == Byte.tab {
            r = trimmedRange(r.lowerBound, q)
        }
        return r
    }

    func endsWithDoubleDollar(_ start: Int, _ end: Int) -> Bool {
        let t = trimmedRange(start, end)
        return t.count >= 2 && bytes[t.upperBound - 1] == Byte.dollar && bytes[t.upperBound - 2] == Byte.dollar
    }

    // MARK: Inline

    mutating func scanInline(from start: Int, to end: Int, line: Int) {
        computeBracketMatches(from: start, to: end)
        var j = start
        while j < end {
            let b = bytes[j]
            switch b {
            case Byte.backslash:
                j += 2
            case Byte.backtick:
                var k = j
                while k < end, bytes[k] == Byte.backtick { k += 1 }
                let run = k - j
                if let close = findBacktickRun(length: run, from: k, to: end) {
                    j = close + run
                } else {
                    j = k
                }
            case Byte.percent where j + 1 < end && bytes[j + 1] == Byte.percent:
                if let close = find(Byte.percent, Byte.percent, from: j + 2, to: end) {
                    document.hiddenRanges.append(j..<(close + 2))
                    j = close + 2
                } else {
                    mode = .percentComment(start: j)
                    return
                }
            case Byte.lt where matches("<!--", at: j, end: end):
                if let close = findSequence(Array("-->".utf8), from: j + 4, to: end) {
                    document.hiddenRanges.append(j..<(close + 3))
                    j = close + 3
                } else {
                    mode = .htmlComment(start: j)
                    return
                }
            case Byte.bang where j + 1 < end && bytes[j + 1] == Byte.openBracket:
                if j + 2 < end, bytes[j + 2] == Byte.openBracket, let next = wikiLink(at: j + 1, embedStart: j, end: end, line: line) {
                    j = next
                } else if let next = markdownLink(at: j + 1, embedStart: j, end: end, line: line) {
                    j = next
                } else {
                    j += 1
                }
            case Byte.openBracket:
                if j + 1 < end, bytes[j + 1] == Byte.openBracket, let next = wikiLink(at: j, embedStart: nil, end: end, line: line) {
                    j = next
                } else if let next = markdownLink(at: j, embedStart: nil, end: end, line: line) {
                    j = next
                } else {
                    j += 1
                }
            case Byte.hash:
                if let next = tag(at: j, lineStart: start, end: end, line: line) {
                    j = next
                } else {
                    j += 1
                }
            default:
                j += 1
            }
        }
    }

    /// Parses `[[...]]` starting at `open` (the first "["). Returns the index
    /// after the closing "]]".
    mutating func wikiLink(at open: Int, embedStart: Int?, end: Int, line: Int) -> Int? {
        let innerStart = open + 2
        var k = innerStart
        while k + 1 < end {
            if bytes[k] == Byte.closeBracket && bytes[k + 1] == Byte.closeBracket { break }
            if bytes[k] == Byte.openBracket && bytes[k + 1] == Byte.openBracket { return nil }
            k += 1
        }
        guard k + 1 < end, k > innerStart else { return nil }
        let inner = string(innerStart..<k)
        let tokenStart = embedStart ?? open
        document.links.append(ScannedLink(
            kind: .wiki,
            isEmbed: embedStart != nil,
            raw: inner,
            text: nil,
            target: LinkTarget.parseWiki(inner),
            range: tokenStart..<(k + 2),
            line: line
        ))
        return k + 2
    }

    /// Parses `[text](destination "title")` starting at `open`. Only links to
    /// vault-internal destinations are recorded; external links are skipped
    /// but still consumed so their text is not scanned for tags.
    /// One pass per line pairing "[" with "]" (skipping escapes and code
    /// spans), so finding the end of a link text is O(1) instead of a rescan
    /// to the end of the line for every "[" (quadratic on "[a[a[a…").
    mutating func computeBracketMatches(from start: Int, to end: Int) {
        bracketMatches.removeAll(keepingCapacity: true)
        var stack: [Int] = []
        var k = start
        while k < end {
            let b = bytes[k]
            if b == Byte.backslash { k += 2; continue }
            if b == Byte.backtick {
                var m = k
                while m < end, bytes[m] == Byte.backtick { m += 1 }
                if let close = findBacktickRun(length: m - k, from: m, to: end) {
                    k = close + (m - k)
                } else {
                    k = m
                }
                continue
            }
            if b == Byte.openBracket { stack.append(k) }
            if b == Byte.closeBracket, let open = stack.popLast() { bracketMatches[open] = k }
            k += 1
        }
    }

    mutating func markdownLink(at open: Int, embedStart: Int?, end: Int, line: Int) -> Int? {
        guard let closeText = bracketMatches[open], closeText + 1 < end, bytes[closeText + 1] == Byte.openParen else { return nil }
        var p = closeText + 2
        while p < end, bytes[p] == Byte.space { p += 1 }
        let destStart: Int
        let destEnd: Int
        if p < end, bytes[p] == Byte.lt {
            var q = p + 1
            while q < end, bytes[q] != Byte.gt { q += 1 }
            guard q < end else { return nil }
            destStart = p + 1
            destEnd = q
            p = q + 1
        } else {
            var parens = 0
            var q = p
            while q < end {
                let b = bytes[q]
                if b == Byte.backslash { q += 2; continue }
                if b == Byte.space || b == Byte.tab { break }
                if b == Byte.openParen { parens += 1 }
                if b == Byte.closeParen {
                    if parens == 0 { break }
                    parens -= 1
                }
                q += 1
            }
            destStart = p
            destEnd = min(q, end)
            p = destEnd
        }
        while p < end, bytes[p] == Byte.space { p += 1 }
        if p < end, bytes[p] == Byte.quote || bytes[p] == Byte.apostrophe {
            let quote = bytes[p]
            var q = p + 1
            while q < end, bytes[q] != quote { q += 1 }
            guard q < end else { return nil }
            p = q + 1
            while p < end, bytes[p] == Byte.space { p += 1 }
        }
        guard p < end, bytes[p] == Byte.closeParen else { return nil }
        let tokenEnd = p + 1
        let destination = string(destStart..<destEnd)
        guard !destination.isEmpty else { return tokenEnd }
        if !LinkTarget.isExternal(markdownDestination: destination) {
            document.links.append(ScannedLink(
                kind: .markdown,
                isEmbed: embedStart != nil,
                raw: destination,
                text: string((open + 1)..<closeText),
                target: LinkTarget.parseMarkdown(destination: destination),
                range: (embedStart ?? open)..<tokenEnd,
                line: line
            ))
        }
        return tokenEnd
    }

    /// Parses `#tag` at `p`. Obsidian requires the "#" to start the line or
    /// follow whitespace, and the tag to contain at least one non-digit.
    mutating func tag(at p: Int, lineStart: Int, end: Int, line: Int) -> Int? {
        if p > lineStart {
            let prev = bytes[p - 1]
            guard prev == Byte.space || prev == Byte.tab else { return nil }
        }
        var q = p + 1
        var sawNonDigit = false
        while q < end {
            let b = bytes[q]
            if b < 0x80 {
                let isDigit = b >= 0x30 && b <= 0x39
                let isLetter = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                if isLetter || b == UInt8(ascii: "_") || b == Byte.dash || b == UInt8(ascii: "/") {
                    sawNonDigit = true
                    q += 1
                } else if isDigit {
                    q += 1
                } else {
                    break
                }
            } else {
                guard let (scalar, length) = decodeScalar(at: q, end: end) else { break }
                let props = scalar.properties
                let joinsEmoji = scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) || scalar.value == 0x20E3
                if props.isAlphabetic || props.numericType != nil || props.generalCategory == .nonspacingMark
                    || props.generalCategory == .spacingMark || props.isEmojiPresentation || props.isEmoji
                    || props.isEmojiModifier || joinsEmoji {
                    sawNonDigit = true
                    q += length
                } else {
                    break
                }
            }
        }
        // Trailing "/" is not part of a nested tag.
        while q > p + 1, bytes[q - 1] == UInt8(ascii: "/") { q -= 1 }
        guard q > p + 1, sawNonDigit else { return nil }
        document.tags.append(ScannedTag(name: string((p + 1)..<q), range: p..<q, line: line))
        return q
    }

    mutating func checkBlockID(start: Int, end: Int, line: Int, hiddenFrom: Int = Int.max) {
        let t = trimmedRange(start, end)
        guard !t.isEmpty else { return }
        var q = t.upperBound
        while q > t.lowerBound {
            let b = bytes[q - 1]
            let ok = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == Byte.dash
            if !ok { break }
            q -= 1
        }
        guard q < t.upperBound, q - 1 >= t.lowerBound, bytes[q - 1] == Byte.caret else { return }
        let caret = q - 1
        var markerStart = caret
        if caret > t.lowerBound {
            let prev = bytes[caret - 1]
            guard prev == Byte.space || prev == Byte.tab else { return }
            markerStart = caret - 1
            while markerStart > start, bytes[markerStart - 1] == Byte.space || bytes[markerStart - 1] == Byte.tab {
                markerStart -= 1
            }
        }
        // Don't let a block id overlap a token we already recorded on this line.
        if let last = document.links.last, last.range.upperBound > markerStart, last.line == line { return }
        // Nor one inside a comment (closed on this line, or still open).
        if hiddenFrom < document.hiddenRanges.count,
           document.hiddenRanges[hiddenFrom...].contains(where: { $0.lowerBound <= markerStart && $0.upperBound > caret }) { return }
        switch mode {
        case .percentComment(let commentStart), .htmlComment(let commentStart):
            if commentStart <= caret { return }
        default:
            break
        }
        document.blockIDs.append(ScannedBlockID(id: string(q..<t.upperBound), range: markerStart..<t.upperBound, line: line))
    }

    // MARK: Utilities

    func string(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    func trimmedRange(_ start: Int, _ end: Int) -> Range<Int> {
        var s = start
        var e = end
        while s < e, bytes[s] == Byte.space || bytes[s] == Byte.tab { s += 1 }
        while e > s, bytes[e - 1] == Byte.space || bytes[e - 1] == Byte.tab { e -= 1 }
        return s..<e
    }

    func trimmed(_ start: Int, _ end: Int) -> UnsafeBufferPointer<UInt8>.SubSequence {
        bytes[trimmedRange(start, end)]
    }

    func matches(_ literal: StaticString, at p: Int, end: Int) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard p + count <= end else { return false }
        return literal.withUTF8Buffer { lit in
            for i in 0..<count where bytes[p + i] != lit[i] { return false }
            return true
        }
    }

    func find(_ a: UInt8, _ b: UInt8, from start: Int, to end: Int) -> Int? {
        var k = start
        while k + 1 < end {
            if bytes[k] == a && bytes[k + 1] == b { return k }
            k += 1
        }
        return nil
    }

    func findSequence(_ seq: [UInt8], from start: Int, to end: Int) -> Int? {
        guard !seq.isEmpty, end - start >= seq.count else { return nil }
        var k = start
        while k + seq.count <= end {
            var ok = true
            for i in 0..<seq.count where bytes[k + i] != seq[i] { ok = false; break }
            if ok { return k }
            k += 1
        }
        return nil
    }

    func findBacktickRun(length: Int, from start: Int, to end: Int) -> Int? {
        var k = start
        while k < end {
            if bytes[k] == Byte.backtick {
                var m = k
                while m < end, bytes[m] == Byte.backtick { m += 1 }
                if m - k == length { return k }
                k = m
            } else {
                k += 1
            }
        }
        return nil
    }

    func decodeScalar(at p: Int, end: Int) -> (Unicode.Scalar, Int)? {
        let b0 = bytes[p]
        let length: Int
        var value: UInt32
        if b0 & 0xE0 == 0xC0 { length = 2; value = UInt32(b0 & 0x1F) }
        else if b0 & 0xF0 == 0xE0 { length = 3; value = UInt32(b0 & 0x0F) }
        else if b0 & 0xF8 == 0xF0 { length = 4; value = UInt32(b0 & 0x07) }
        else { return nil }
        guard p + length <= end else { return nil }
        for i in 1..<length {
            let b = bytes[p + i]
            guard b & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(b & 0x3F)
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }
}
