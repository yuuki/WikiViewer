//
//  NoteRenderer.swift
//  WikiViewerKit
//
//  On-demand presentation parsing of ONE note:
//
//    stored raw Markdown ──ObsidianScanner──▶ tokens
//      tokens + link rows (resolved on the host) ──rewrite──▶ CommonMark with
//      explicit link/embed nodes ──swift-markdown──▶ AST ──▶ [RenderBlock]
//
//  Obsidian constructs are not handled by global regex substitution: the
//  shared, code-aware scanner reports exact byte ranges (outside code spans,
//  fences and comments), and each token is replaced by a standard Markdown
//  link or image whose URL identifies the resolved target. Line structure is
//  preserved so block IDs map back to source lines.
//

import Foundation
import Markdown
import SwiftUI
import WikiShared

public struct RenderedNote: Sendable {
    public var blocks: [RenderBlock]
    /// HeadingKey → id of the top-level block to scroll to.
    public var headingAnchors: [String: Int]
    /// Block ID (without ^) → id of the top-level block to scroll to.
    public var blockAnchors: [String: Int]
    public var headings: [(level: Int, text: String, blockID: Int)]
}

extension RenderedNote {
    /// Id of the first top-level block whose visible text contains `text`
    /// (case-insensitive), to open a search result at its match. Markdown
    /// syntax is not visible, so a match only inside it is not found.
    public func firstBlock(containing text: String) -> Int? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return blocks.first { $0.plainText.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }?.id
    }
}

extension RenderBlock {
    /// The text a reader sees in this block, children included.
    public var plainText: String {
        switch kind {
        case .heading(_, let text), .paragraph(let text): String(text.characters)
        case .code(_, let code, _): code
        case .math(let latex): latex
        case .quote(let children): children.map(\.plainText).joined(separator: "\n")
        case .callout(_, let title, _, let children): ([String(title.characters)] + children.map(\.plainText)).joined(separator: "\n")
        case .listItem(_, _, let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .table(let header, let rows): (header + rows.flatMap { $0 }).map { String($0.characters) }.joined(separator: " ")
        case .rule, .embed: ""
        case .html(let raw): raw
        }
    }
}

public struct RenderBlock: Identifiable, Sendable {
    public var id: Int
    public var kind: Kind
    /// Zero-based source line where the block starts (for block anchors).
    public var line: Int = 0

    public indirect enum Kind: Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// Long code blocks are split into several parts (`continuation`) so
        /// each part is a separate lazily created row.
        case code(language: String?, code: String, continuation: Bool)
        case quote([RenderBlock])
        case callout(type: String, title: AttributedString, foldable: Bool, children: [RenderBlock])
        /// Lists are flattened: every item (at any nesting depth) is its own
        /// block, so a 100k-item outline is rendered lazily row by row.
        case listItem(marker: ListMarker, depth: Int, blocks: [RenderBlock])
        /// Large tables are split into parts; parts after the first have no header.
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
        case embed(EmbedTarget)
        /// `$$…$$` display math, as LaTeX source.
        case math(String)
        case html(String)
    }
}

public enum ListMarker: Sendable, Equatable {
    case bullet
    case number(Int)
    case task(done: Bool)
}

/// Marks inline `$…$` math in a paragraph's AttributedString. The run's
/// characters are the LaTeX source, so search and copying see the formula;
/// the value is the same source, for the view to typeset.
public enum MathAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "WikiViewer.math"
}

public enum EmbedTarget: Sendable, Hashable {
    case asset(id: Int64, name: String, sizeSpec: String?)
    case note(id: Int64, title: String, heading: String?, blockID: String?)
    case missing(raw: String)
}

public enum NoteRenderer {
    /// Renders a note body. `allowEmbeds == false` turns embeds into links
    /// (used inside embedded notes to bound nesting to one level).
    public static func render(body: String, noteID: Int64, links: [OutgoingLink], allowEmbeds: Bool = true) -> RenderedNote {
        let pre = Preprocessor.run(body: body, noteID: noteID, links: links, allowEmbeds: allowEmbeds)
        let document = Document(parsing: pre.text)
        var builder = BlockBuilder(embeds: pre.embeds, math: pre.math)
        var blocks: [RenderBlock] = []
        for child in document.children {
            blocks.append(contentsOf: builder.blocks(for: child))
        }
        // Each ^block-id belongs to the last top-level block starting at or
        // before its line. Both sequences are in document order: one linear pass.
        var blockAnchors: [String: Int] = [:]
        var owner = 0
        for (line, blockID) in pre.blockIDsByLine.sorted(by: { $0.key < $1.key }) where !blocks.isEmpty {
            while owner + 1 < blocks.count, blocks[owner + 1].line <= line { owner += 1 }
            blockAnchors[blockID] = blockAnchors[blockID] ?? blocks[owner].id
        }
        var headingAnchors: [String: Int] = [:]
        var headings: [(Int, String, Int)] = []
        for block in blocks {
            if case .heading(let level, let text) = block.kind {
                let plain = String(text.characters)
                let key = HeadingKey.make(plain)
                if headingAnchors[key] == nil { headingAnchors[key] = block.id }
                headings.append((level, plain, block.id))
            }
        }
        return RenderedNote(blocks: blocks, headingAnchors: headingAnchors, blockAnchors: blockAnchors, headings: headings)
    }

    /// Extracts the section of `body` under the heading matching `heading`
    /// (up to the next heading of the same or higher level), or the block
    /// with `blockID`. Used for `![[note#Heading]]` / `![[note#^id]]` embeds.
    public static func excerpt(body: String, heading: String?, blockID: String?) -> String {
        let scanned = ObsidianScanner().scan(body)
        // Split on "\n" scalars like the scanner does (a Character split would
        // treat "\r\n" as one character and disagree with scanner line numbers).
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring(String($0)) }
        if let heading {
            let key = HeadingKey.make(HeadingKey.lastComponent(of: heading))
            guard let index = scanned.headings.firstIndex(where: { HeadingKey.make($0.text) == key }),
                  scanned.headings[index].line < lines.count else { return body }
            let start = scanned.headings[index]
            let end = scanned.headings[(index + 1)...].first { $0.level <= start.level }?.line ?? lines.count
            return lines[start.line..<max(start.line, min(end, lines.count))].joined(separator: "\n")
        }
        if let blockID, let block = scanned.blockIDs.first(where: { $0.id == blockID }), block.line < lines.count {
            var first = block.line
            // A standalone "^id" line refers to the block above it.
            let own = lines[block.line].trimmingCharacters(in: .whitespaces)
            if own == "^" + blockID, first > 0 { first -= 1 }
            func isBoundary(_ line: Substring) -> Bool {
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.hasPrefix("#") && (t.drop(while: { $0 == "#" }).first.map { $0 == " " } ?? true)
            }
            func isListItem(_ line: Substring) -> Bool {
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") || t.prefix(while: \.isNumber).count > 0 && t.drop(while: \.isNumber).hasPrefix(". ")
            }
            // A list item block is just that item; a paragraph extends up to
            // the previous blank line or heading.
            if !isListItem(lines[first]) {
                while first > 0, !isBoundary(lines[first - 1]), !isListItem(lines[first - 1]) { first -= 1 }
            }
            return lines[first...block.line].joined(separator: "\n")
        }
        return body
    }
}

// MARK: - Properties

extension NoteRenderer {
    /// A frontmatter value as display text. Wikilinks inside string values
    /// (`up: "[[Home]]"`) become links, resolved through the note's link
    /// rows (the indexer stores them after the body links).
    public static func propertyText(_ value: PropertyValue, noteID: Int64, links: [OutgoingLink]) -> AttributedString {
        var byRaw: [String: OutgoingLink] = [:]
        for link in links where link.kind == .wiki && byRaw[link.raw] == nil {
            byRaw[link.raw] = link
        }
        return propertyText(value, noteID: noteID, byRaw: byRaw)
    }

    static func propertyText(_ value: PropertyValue, noteID: Int64, byRaw: [String: OutgoingLink]) -> AttributedString {
        switch value {
        case .text(let s):
            return linkedText(s, noteID: noteID, byRaw: byRaw)
        case .list(let items):
            var out = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(AttributedString(", ")) }
                out.append(propertyText(item, noteID: noteID, byRaw: byRaw))
            }
            return out
        case .object(let props):
            var out = AttributedString()
            for (i, prop) in props.enumerated() {
                if i > 0 { out.append(AttributedString(", ")) }
                out.append(AttributedString(prop.key + ": "))
                out.append(propertyText(prop.value, noteID: noteID, byRaw: byRaw))
            }
            return out
        case .number, .bool, .null:
            return AttributedString(value.displayText)
        }
    }

    static func linkedText(_ s: String, noteID: Int64, byRaw: [String: OutgoingLink]) -> AttributedString {
        guard s.contains("[[") else { return AttributedString(s) }
        let bytes = Array(s.utf8)
        var out = AttributedString()
        var cursor = 0
        for token in ObsidianScanner().scan(s).links where token.kind == .wiki {
            guard token.range.lowerBound >= cursor, token.range.upperBound <= bytes.count else { continue }
            out.append(AttributedString(String(decoding: bytes[cursor..<token.range.lowerBound], as: UTF8.self)))
            var label = AttributedString(Preprocessor.wikiLabel(token.target))
            label.link = Preprocessor.resolve(byRaw[token.raw], token: token, noteID: noteID).url
            out.append(label)
            cursor = token.range.upperBound
        }
        out.append(AttributedString(String(decoding: bytes[cursor...], as: UTF8.self)))
        return out
    }
}

// MARK: - Preprocessing

struct Preprocessor {
    struct Output {
        var text: String
        var embeds: [Int: EmbedTarget]
        var math: [Int: ScannedMath]
        var blockIDsByLine: [Int: String]
    }

    static let embedPrefix = "wikiviewer://embed/"
    static let mathPrefix = "wikiviewer://math/"

    static func run(body: String, noteID: Int64, links: [OutgoingLink], allowEmbeds: Bool) -> Output {
        let scanned = ObsidianScanner().scan(body)
        let bytes = Array(body.utf8)
        var byOrdinal: [Int: OutgoingLink] = [:]
        var byRaw: [String: OutgoingLink] = [:]
        for link in links {
            byOrdinal[link.ordinal] = link
            if byRaw[link.raw] == nil { byRaw[link.raw] = link }
        }

        enum Edit {
            case hidden
            case remove
            case replace(String)
        }
        var edits: [(range: Range<Int>, edit: Edit)] = []
        var embeds: [Int: EmbedTarget] = [:]
        var blockIDsByLine: [Int: String] = [:]

        for range in scanned.hiddenRanges { edits.append((range, .hidden)) }
        // Math becomes an image placeholder, so swift-markdown does not read
        // its backslashes, underscores and asterisks as Markdown. Tokens the
        // scanner found inside inline math ("$a #b$") overlap it and are dropped.
        var math: [Int: ScannedMath] = [:]
        for item in MathScanner().scan(body) {
            let index = math.count
            math[index] = item
            // Keep each line's container prefix so line numbers and
            // blockquotes survive a multi-line block.
            let lines = item.linePrefixes.map { "\n" + $0 }.joined()
            edits.append((item.range, .replace("![](\(mathPrefix)\(index))" + lines)))
        }
        for block in scanned.blockIDs {
            edits.append((block.range, .remove))
            blockIDsByLine[block.line] = block.id
        }
        for tag in scanned.tags {
            let label = escape("#" + tag.name)
            edits.append((tag.range, .replace("[\(label)](<\(WikiLinkAction.tag(tag.name).url.absoluteString)>)")))
        }
        for (ordinal, token) in scanned.links.enumerated() {
            // Rows are matched by ordinal (same scanner on both sides); fall
            // back to the raw text if the scanner versions disagree.
            let row = byOrdinal[ordinal].flatMap { $0.raw == token.raw ? $0 : nil } ?? byRaw[token.raw]
            let action = resolve(row, token: token, noteID: noteID)
            if token.isEmbed && allowEmbeds {
                let index = embeds.count
                let target: EmbedTarget
                if let assetID = row?.targetAssetID {
                    target = .asset(id: assetID, name: VaultPath.fileName(of: token.target.path), sizeSpec: token.kind == .wiki ? token.target.display : nil)
                } else if let noteTarget = row?.targetNoteID {
                    target = .note(id: noteTarget, title: displayPath(token.target.path), heading: token.target.heading, blockID: token.target.blockID)
                } else {
                    target = .missing(raw: token.raw)
                }
                embeds[index] = target
                let alt = escape(token.text ?? token.target.path)
                edits.append((token.range, .replace("![\(alt)](\(embedPrefix)\(index))")))
            } else {
                let label: String
                if token.kind == .markdown {
                    label = token.text ?? token.raw   // already Markdown inline content
                } else {
                    label = escape(wikiLabel(token.target))
                }
                // <…> destinations may contain parentheses (e.g. "[[Foo (draft)]]").
                edits.append((token.range, .replace("[\(label)](<\(action.url.absoluteString)>)")))
            }
        }

        edits.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + edits.count * 32)
        var cursor = 0
        for (range, edit) in edits {
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count else { continue } // overlap: skip defensively
            out.append(contentsOf: bytes[cursor..<range.lowerBound])
            switch edit {
            case .hidden:
                // Keep newlines so line numbers stay aligned with the source.
                out.append(contentsOf: bytes[range].filter { $0 == UInt8(ascii: "\n") })
            case .remove:
                break
            case .replace(let s):
                out.append(contentsOf: s.utf8)
            }
            cursor = range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return Output(text: String(decoding: out, as: UTF8.self), embeds: embeds, math: math, blockIDsByLine: blockIDsByLine)
    }

    static func resolve(_ row: OutgoingLink?, token: ScannedLink, noteID: Int64) -> WikiLinkAction {
        if let id = row?.targetNoteID {
            return .note(id: id, heading: token.target.heading.map { String(HeadingKey.lastComponent(of: $0)) }, blockID: token.target.blockID)
        }
        if let id = row?.targetAssetID { return .asset(id: id) }
        if token.target.path.isEmpty {
            return .note(id: noteID, heading: token.target.heading.map { String(HeadingKey.lastComponent(of: $0)) }, blockID: token.target.blockID)
        }
        return .missing(target: token.target.path)
    }

    /// Obsidian shows `[[note#Heading]]` as "note > Heading".
    static func wikiLabel(_ target: LinkTarget) -> String {
        if let display = target.display, !display.isEmpty { return display }
        var label = displayPath(target.path)
        if let heading = target.heading {
            label += label.isEmpty ? heading.replacingOccurrences(of: "#", with: " > ") : " > " + heading.replacingOccurrences(of: "#", with: " > ")
        }
        if let block = target.blockID { label += (label.isEmpty ? "^" : " > ^") + block }
        return label
    }

    static func displayPath(_ path: String) -> String {
        path.hasSuffix(".md") ? String(path.dropLast(3)) : path
    }

    /// Backslash-escapes ASCII punctuation so labels are literal text.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if let a = c.asciiValue, (33...47).contains(a) || (58...64).contains(a) || (91...96).contains(a) || (123...126).contains(a) {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }
}

// MARK: - AST → blocks

struct BlockBuilder {
    let embeds: [Int: EmbedTarget]
    let math: [Int: ScannedMath]
    var nextID = 0

    init(embeds: [Int: EmbedTarget], math: [Int: ScannedMath] = [:]) {
        self.embeds = embeds
        self.math = math
    }

    mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    static let codeLinesPerBlock = 150
    static let tableRowsPerBlock = 60

    mutating func blocks(for markup: any Markup) -> [RenderBlock] {
        let line = (markup.range?.lowerBound.line ?? 1) - 1
        return uncheckedBlocks(for: markup).map { block in
            var block = block
            if block.line == 0 { block.line = line }
            return block
        }
    }

    mutating func uncheckedBlocks(for markup: any Markup) -> [RenderBlock] {
        switch markup {
        case let heading as Heading:
            return [RenderBlock(id: makeID(), kind: .heading(level: heading.level, text: inlines(heading.children)))]
        case let paragraph as Paragraph:
            return paragraphBlocks(paragraph)
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > Self.codeLinesPerBlock else {
                return [RenderBlock(id: makeID(), kind: .code(language: language, code: text, continuation: false))]
            }
            let start = (code.range?.lowerBound.line ?? 1) - 1
            return stride(from: 0, to: lines.count, by: Self.codeLinesPerBlock).map { i in
                let part = lines[i..<min(i + Self.codeLinesPerBlock, lines.count)].joined(separator: "\n")
                return RenderBlock(id: makeID(), kind: .code(language: language, code: part, continuation: i > 0), line: start + 1 + i)
            }
        case let quote as BlockQuote:
            if let callout = calloutBlock(quote) { return [callout] }
            let children = quote.children.flatMap { blocks(for: $0) }
            return [RenderBlock(id: makeID(), kind: .quote(children))]
        case let list as UnorderedList:
            return listItems(list.children, ordered: false, start: 1, depth: 0)
        case let list as OrderedList:
            return listItems(list.children, ordered: true, start: Int(list.startIndex), depth: 0)
        case let table as Markdown.Table:
            let header = table.head.children.map { inlines($0.children) }
            let rows = table.body.children.map { row in row.children.map { inlines($0.children) } }
            guard rows.count > Self.tableRowsPerBlock else {
                return [RenderBlock(id: makeID(), kind: .table(header: header, rows: rows))]
            }
            return stride(from: 0, to: rows.count, by: Self.tableRowsPerBlock).map { i in
                RenderBlock(id: makeID(), kind: .table(header: i == 0 ? header : [], rows: Array(rows[i..<min(i + Self.tableRowsPerBlock, rows.count)])))
            }
        case is ThematicBreak:
            return [RenderBlock(id: makeID(), kind: .rule)]
        case let html as HTMLBlock:
            let trimmed = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [RenderBlock(id: makeID(), kind: .html(trimmed))]
        default:
            let children = markup.children.flatMap { blocks(for: $0) }
            return children
        }
    }

    /// Flattens a list: one block per item; nested lists become following
    /// items with a greater depth.
    mutating func listItems(_ children: MarkupChildren, ordered: Bool, start: Int, depth: Int) -> [RenderBlock] {
        var result: [RenderBlock] = []
        var number = start
        for child in children {
            guard let item = child as? ListItem else { continue }
            let marker: ListMarker = switch item.checkbox {
            case .checked: .task(done: true)
            case .unchecked: .task(done: false)
            case nil: ordered ? .number(number) : .bullet
            }
            number += 1
            var content: [RenderBlock] = []
            var nested: [RenderBlock] = []
            for part in item.children {
                if let sub = part as? UnorderedList {
                    nested += listItems(sub.children, ordered: false, start: 1, depth: depth + 1)
                } else if let sub = part as? OrderedList {
                    nested += listItems(sub.children, ordered: true, start: Int(sub.startIndex), depth: depth + 1)
                } else {
                    content += blocks(for: part)
                }
            }
            let line = (item.range?.lowerBound.line ?? 1) - 1
            result.append(RenderBlock(id: makeID(), kind: .listItem(marker: marker, depth: depth, blocks: content), line: line))
            result += nested
        }
        return result
    }

    mutating func paragraphBlocks(_ paragraph: Paragraph) -> [RenderBlock] {
        paragraphBlocks(Array(paragraph.children))
    }

    /// Splits a paragraph around embed and display math images so they
    /// become blocks.
    mutating func paragraphBlocks(_ children: [any Markup]) -> [RenderBlock] {
        // Group inline children into runs separated by embed images.
        var runs: [Either] = []
        var pending: [any Markup] = []
        for child in children {
            if let image = child as? Markdown.Image, let embed = embedTarget(image) {
                runs.append(.inlines(pending))
                pending.removeAll()
                runs.append(.embed(embed))
            } else if let image = child as? Markdown.Image, let math = mathSource(image), math.display {
                runs.append(.inlines(pending))
                pending.removeAll()
                runs.append(.math(math.latex))
            } else {
                pending.append(child)
            }
        }
        runs.append(.inlines(pending))

        var result: [RenderBlock] = []
        for run in runs {
            switch run {
            case .embed(let embed):
                result.append(RenderBlock(id: makeID(), kind: .embed(embed)))
            case .math(let latex):
                result.append(RenderBlock(id: makeID(), kind: .math(latex)))
            case .inlines(let nodes):
                guard !nodes.isEmpty else { continue }
                let text = inlines(nodes)
                if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(RenderBlock(id: makeID(), kind: .paragraph(trimmed(text))))
                }
            }
        }
        return result
    }

    enum Either {
        case inlines([any Markup])
        case embed(EmbedTarget)
        case math(String)
    }

    func mathSource(_ image: Markdown.Image) -> ScannedMath? {
        guard let source = image.source, source.hasPrefix(Preprocessor.mathPrefix),
              let index = Int(source.dropFirst(Preprocessor.mathPrefix.count)) else { return nil }
        return math[index]
    }

    func embedTarget(_ image: Markdown.Image) -> EmbedTarget? {
        guard let source = image.source, source.hasPrefix(Preprocessor.embedPrefix),
              let index = Int(source.dropFirst(Preprocessor.embedPrefix.count)) else { return nil }
        return embeds[index]
    }

    /// `> [!type]± Title` blockquotes become callouts.
    mutating func calloutBlock(_ quote: BlockQuote) -> RenderBlock? {
        guard let first = quote.child(at: 0) as? Paragraph,
              let text = first.child(at: 0) as? Markdown.Text,
              text.string.hasPrefix("[!"),
              let close = text.string.firstIndex(of: "]") else { return nil }
        let type = String(text.string[text.string.index(text.string.startIndex, offsetBy: 2)..<close]).lowercased()
        var rest = String(text.string[text.string.index(after: close)...])
        var foldable = false
        if rest.hasPrefix("-") || rest.hasPrefix("+") {
            foldable = true
            rest.removeFirst()
        }
        // Title: rest of the first line; body: everything after the first line break.
        var titleNodes: [any Markup] = []
        var bodyNodes: [any Markup] = []
        var inBody = false
        for (i, child) in first.children.enumerated() where i > 0 {
            if !inBody, child is SoftBreak || child is LineBreak {
                inBody = true
                continue
            }
            if inBody { bodyNodes.append(child) } else { titleNodes.append(child) }
        }
        // Only the leading space: the text may continue with inline nodes
        // (math, emphasis) after a space. The whole title is trimmed below.
        var title = AttributedString(String(rest.drop(while: \.isWhitespace)))
        title.append(inlines(titleNodes))
        if String(title.characters).trimmingCharacters(in: .whitespaces).isEmpty {
            title = AttributedString(type.prefix(1).uppercased() + type.dropFirst())
        }
        var children: [RenderBlock] = []
        children += paragraphBlocks(bodyNodes)
        for child in quote.children.dropFirst() {
            children.append(contentsOf: blocks(for: child))
        }
        return RenderBlock(id: makeID(), kind: .callout(type: type, title: trimmed(title), foldable: foldable, children: children))
    }

    // MARK: Inlines

    func inlines(_ nodes: some Sequence<any Markup>) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            out.append(inline(node, intent: [], link: nil))
        }
        return out
    }

    func inlines(_ children: MarkupChildren) -> AttributedString {
        inlines(Array(children))
    }

    func inline(_ markup: any Markup, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        func styled(_ string: String, _ intent: InlinePresentationIntent) -> AttributedString {
            var s = AttributedString(string)
            if !intent.isEmpty { s.inlinePresentationIntent = intent }
            if let link {
                s.link = link
                if case .missing = WikiLinkAction(url: link) {
                    s.foregroundColor = .secondary
                }
            }
            return s
        }
        func children(_ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
            var out = AttributedString()
            for child in markup.children {
                out.append(inline(child, intent: intent, link: link))
            }
            return out
        }
        switch markup {
        case let text as Markdown.Text:
            return styled(text.string, intent)
        case is Emphasis:
            return children(intent.union(.emphasized), link)
        case is Strong:
            return children(intent.union(.stronglyEmphasized), link)
        case is Strikethrough:
            return children(intent.union(.strikethrough), link)
        case let code as InlineCode:
            return styled(code.code, intent.union(.code))
        case let l as Markdown.Link:
            // Only in-app targets and http(s)/mailto become tappable; other
            // schemes (tel:, shortcuts:, file:, custom apps) render as text.
            let url = l.destination.flatMap { URL(string: $0) }.flatMap { WikiLinkAction(url: $0) != nil ? $0 : nil }
            return children(intent, url ?? link)
        case let image as Markdown.Image where mathSource(image) != nil:
            // Math left inline (e.g. in a heading or table cell) is typeset
            // in text style; its characters are the source.
            let latex = mathSource(image)?.latex ?? ""
            var s = styled(latex, intent)
            s[MathAttribute.self] = latex
            return s
        case let image as Markdown.Image:
            // Non-embed images (e.g. remote URLs) are not fetched: privacy and
            // bounded memory. They render as a link with their alt text.
            let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
            var s = styled("🖼 " + alt, intent)
            if let src = image.source, let url = URL(string: src), WikiLinkAction(url: url) != nil { s.link = url }
            return s
        case is SoftBreak:
            return styled(" ", intent)
        case is LineBreak:
            return styled("\n", intent)
        case let html as InlineHTML:
            let raw = html.rawHTML.lowercased()
            if raw.hasPrefix("<br") { return styled("\n", intent) }
            return styled(html.rawHTML, intent.union(.code))
        default:
            return children(intent, link)
        }
    }

    func trimmed(_ s: AttributedString) -> AttributedString {
        var s = s
        while let first = s.characters.first, first.isWhitespace || first.isNewline {
            s.removeSubrange(s.startIndex..<s.index(afterCharacter: s.startIndex))
        }
        while let last = s.characters.last, last.isWhitespace || last.isNewline {
            s.removeSubrange(s.index(beforeCharacter: s.endIndex)..<s.endIndex)
        }
        return s
    }
}
