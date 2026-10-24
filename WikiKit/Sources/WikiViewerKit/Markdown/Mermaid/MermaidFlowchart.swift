//
//  MermaidFlowchart.swift
//  WikiViewerKit
//
//  Parses the flowchart subset of Mermaid (```` ```mermaid ```` code blocks
//  starting with `flowchart` or `graph`) into a model that MermaidLayout
//  lays out and the app draws natively; there is no web view. Covered:
//  directions, node shapes, quoted labels with <br>, edge strokes, arrow
//  heads and labels, chains (`A --> B --> C`), `&` groups and nested
//  subgraphs with their own direction. Styling (`style`, `classDef`,
//  `class`, `:::`, `linkStyle`) and `click` are ignored. Other diagram
//  types, and text the parser does not understand, are shown as code.
//

import Foundation

public struct MermaidFlowchart: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case down, up, right, left
    }

    public enum Shape: Sendable, Equatable {
        case rectangle, rounded, stadium, subroutine, cylinder, circle, doubleCircle
        case rhombus, hexagon, parallelogram, parallelogramAlt, trapezoid, trapezoidAlt, asymmetric
    }

    public struct Node: Sendable, Equatable {
        public var id: String
        public var label: String
        public var shape: Shape
    }

    public enum Stroke: Sendable, Equatable {
        case solid, dotted, thick, invisible
    }

    public enum ArrowHead: Sendable, Equatable {
        case arrow, circle, cross
    }

    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String?
        public var stroke: Stroke
        public var head: ArrowHead?
        public var tail: ArrowHead?
    }

    public struct Subgraph: Sendable, Equatable {
        public var id: String
        public var title: String
        public var direction: Direction?
        /// Id of the enclosing subgraph, nil at the top level.
        public var parent: String?
    }

    public var direction: Direction
    /// In order of first appearance.
    public var nodes: [Node]
    public var edges: [Edge]
    /// In order of appearance; a parent comes before its children.
    public var subgraphs: [Subgraph]
    /// Node id → id of the innermost subgraph it belongs to.
    public var membership: [String: String]

    /// Node labels, edge labels and subgraph titles, for find in note.
    public var plainText: String {
        (subgraphs.map(\.title) + nodes.map(\.label) + edges.compactMap(\.label))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension MermaidFlowchart {
    /// nil when `source` is not a flowchart or uses syntax this parser does
    /// not understand: the caller shows the source instead.
    public init?(source: String) {
        var parser = MermaidFlowchartParser()
        guard let chart = parser.parse(source) else { return nil }
        self = chart
    }
}

private struct MermaidFlowchartParser {
    var nodes: [MermaidFlowchart.Node] = []
    var nodeIndex: [String: Int] = [:]
    var explicitShape: Set<String> = []
    var edges: [MermaidFlowchart.Edge] = []
    var subgraphs: [MermaidFlowchart.Subgraph] = []
    var membership: [String: String] = [:]
    var stack: [Int] = []
    var anonymousSubgraphs = 0

    mutating func parse(_ source: String) -> MermaidFlowchart? {
        var lines = Self.statements(source)
        // Front matter (`---` … `---`) and `%%{init}%%` directives come first.
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...close)
        }
        guard let header = lines.first else { return nil }
        let words = header.split(whereSeparator: \.isWhitespace)
        guard let keyword = words.first, keyword == "flowchart" || keyword == "graph" else { return nil }
        var direction = MermaidFlowchart.Direction.down
        if words.count > 1 {
            guard let parsed = Self.direction(String(words[1])) else { return nil }
            direction = parsed
        }
        for line in lines.dropFirst() {
            guard statement(line) else { return nil }
        }
        // A subgraph id used as an edge end is the subgraph, not a node.
        let subgraphIDs = Set(subgraphs.map(\.id))
        nodes.removeAll { subgraphIDs.contains($0.id) && !explicitShape.contains($0.id) }
        for id in subgraphIDs where !nodes.contains(where: { $0.id == id }) {
            membership[id] = nil
        }
        guard !nodes.isEmpty else { return nil }
        return MermaidFlowchart(direction: direction, nodes: nodes, edges: edges, subgraphs: subgraphs, membership: membership)
    }

    /// Lines with comments removed, trimmed, split at `;`, empty ones
    /// dropped. A quoted label may run over several lines.
    static func statements(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if quoted {
                current.append("\n")
            } else if line.hasPrefix("%%") || line.isEmpty {
                continue
            }
            for character in line {
                if character == "\"" { quoted.toggle() }
                if character == ";" && !quoted {
                    result.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !quoted {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func direction(_ word: String) -> MermaidFlowchart.Direction? {
        switch word.uppercased() {
        case "TB", "TD": .down
        case "BT": .up
        case "LR": .right
        case "RL": .left
        default: nil
        }
    }

    mutating func statement(_ line: String) -> Bool {
        let first = line.prefix { !$0.isWhitespace }
        let rest = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
        switch first {
        case "subgraph":
            openSubgraph(rest)
            return true
        case "end":
            guard rest.isEmpty, !stack.isEmpty else { return false }
            stack.removeLast()
            return true
        case "direction":
            guard let direction = Self.direction(rest) else { return false }
            if let open = stack.last { subgraphs[open].direction = direction }
            return true
        case "style", "classDef", "class", "linkStyle", "click", "accTitle", "accTitle:", "accDescr", "accDescr:":
            return true
        default:
            return chain(line)
        }
    }

    mutating func openSubgraph(_ rest: String) {
        var scanner = Scanner(rest)
        var id = scanner.identifier()
        var title = id
        scanner.skipSpaces()
        if scanner.peek == "[", let label = scanner.bracketed(open: "[", close: "]") {
            title = label
        } else if id.isEmpty, scanner.peek == "\"", let quoted = scanner.quoted() {
            title = quoted
        } else if !scanner.atEnd {
            // `subgraph Some title`: the whole text is both id and title.
            title = rest.trimmingCharacters(in: .whitespaces)
            id = title
        }
        if id.isEmpty {
            anonymousSubgraphs += 1
            id = "subgraph-\(anonymousSubgraphs)"
        }
        let parent = stack.last.map { subgraphs[$0].id }
        subgraphs.append(MermaidFlowchart.Subgraph(id: id, title: Self.cleanLabel(title), direction: nil, parent: parent))
        stack.append(subgraphs.count - 1)
    }

    /// `A & B --> C -->|x| D`: node groups joined by links.
    mutating func chain(_ line: String) -> Bool {
        var scanner = Scanner(line)
        guard var previous = group(&scanner) else { return false }
        while true {
            scanner.skipSpaces()
            if scanner.atEnd { return true }
            guard let link = scanner.link() else { return false }
            scanner.skipSpaces()
            guard let next = group(&scanner) else { return false }
            for from in previous {
                for to in next {
                    edges.append(MermaidFlowchart.Edge(from: from, to: to, label: link.label.map(Self.cleanLabel),
                                                       stroke: link.stroke, head: link.head, tail: link.tail))
                }
            }
            previous = next
        }
    }

    mutating func group(_ scanner: inout Scanner) -> [String]? {
        var ids: [String] = []
        repeat {
            scanner.skipSpaces()
            guard let id = node(&scanner) else { return nil }
            ids.append(id)
            scanner.skipSpaces()
        } while scanner.consume("&")
        return ids
    }

    mutating func node(_ scanner: inout Scanner) -> String? {
        let id = scanner.identifier()
        guard !id.isEmpty else { return nil }
        var shaped: (MermaidFlowchart.Shape, String)?
        for (open, close, shape) in Self.shapes where scanner.hasPrefix(open) {
            let start = scanner.index
            if let label = scanner.bracketed(open: open, close: close) {
                shaped = (shape, label)
                break
            }
            scanner.index = start
        }
        // `@{ shape: … }` (Mermaid 11) and `:::class` are not drawn.
        if scanner.hasPrefix("@{") {
            guard let close = scanner.text[scanner.index...].firstIndex(of: "}") else { return nil }
            scanner.index = scanner.text.index(after: close)
        }
        if scanner.consume(":::") { _ = scanner.identifier() }
        declare(id, shaped.map { ($0.0, Self.cleanLabel($0.1)) })
        return id
    }

    mutating func declare(_ id: String, _ shaped: (MermaidFlowchart.Shape, String)?) {
        if let index = nodeIndex[id] {
            if let shaped {
                nodes[index].shape = shaped.0
                nodes[index].label = shaped.1
                explicitShape.insert(id)
            }
        } else {
            nodeIndex[id] = nodes.count
            nodes.append(MermaidFlowchart.Node(id: id, label: shaped?.1 ?? id, shape: shaped?.0 ?? .rectangle))
            if shaped != nil { explicitShape.insert(id) }
        }
        // A node belongs to the first subgraph that mentions it, even if it
        // appeared outside one before (as in Mermaid).
        if let open = stack.last, membership[id] == nil, subgraphs[open].id != id {
            membership[id] = subgraphs[open].id
        }
    }

    /// Longest delimiters first, so `((` is not read as `(`.
    static let shapes: [(String, String, MermaidFlowchart.Shape)] = [
        ("(((", ")))", .doubleCircle),
        ("((", "))", .circle),
        ("([", "])", .stadium),
        ("[[", "]]", .subroutine),
        ("[(", ")]", .cylinder),
        ("[/", "/]", .parallelogram),
        ("[/", "\\]", .trapezoid),
        ("[\\", "\\]", .parallelogramAlt),
        ("[\\", "/]", .trapezoidAlt),
        ("{{", "}}", .hexagon),
        ("[", "]", .rectangle),
        ("(", ")", .rounded),
        ("{", "}", .rhombus),
        (">", "]", .asymmetric),
    ]

    /// `<br>` becomes a line break, other tags and Markdown string
    /// backticks are dropped, and common entities are decoded.
    static func cleanLabel(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^<>]*>"#, with: "", options: .regularExpression)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        for (entity, character) in [("#quot;", "\""), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("#35;", "#"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

private struct Link {
    var stroke: MermaidFlowchart.Stroke
    var head: MermaidFlowchart.ArrowHead?
    var tail: MermaidFlowchart.ArrowHead?
    var label: String?
}

private struct Scanner {
    let text: String
    var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    var atEnd: Bool { index == text.endIndex }
    var peek: Character? { atEnd ? nil : text[index] }

    func hasPrefix(_ prefix: String) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    mutating func consume(_ prefix: String) -> Bool {
        guard hasPrefix(prefix) else { return false }
        index = text.index(index, offsetBy: prefix.count)
        return true
    }

    mutating func skipSpaces() {
        while let c = peek, c.isWhitespace { index = text.index(after: index) }
    }

    /// Letters, digits, `_` and any non-ASCII character; `-` and `.` only
    /// when they cannot start a link (`user-db`, but not `A-->B`).
    mutating func identifier() -> String {
        let start = index
        while let c = peek {
            if c.isLetter || c.isNumber || c == "_" || !c.isASCII {
                index = text.index(after: index)
            } else if c == "-" || c == "." {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                let n = text[next]
                if n.isLetter || n.isNumber || n == "_" || !n.isASCII {
                    index = next
                } else {
                    break
                }
            } else {
                break
            }
        }
        return String(text[start..<index])
    }

    mutating func quoted() -> String? {
        guard consume("\"") else { return nil }
        guard let close = text[index...].firstIndex(of: "\"") else { return nil }
        let value = String(text[index..<close])
        index = text.index(after: close)
        return value
    }

    /// The text between `open` and `close`, quoted or not.
    mutating func bracketed(open: String, close: String) -> String? {
        guard consume(open) else { return nil }
        skipSpaces()
        if peek == "\"" {
            let start = index
            if let value = quoted() {
                skipSpaces()
                if consume(close) { return value }
            }
            index = start
        }
        guard let range = text[index...].range(of: close) else { return nil }
        let value = String(text[index..<range.lowerBound])
        index = range.upperBound
        return value
    }

    /// One link, with its label (`-- text -->` or `-->|text|`).
    mutating func link() -> Link? {
        let start = index
        if consume("~~~") {
            while consume("~") {}
            return Link(stroke: .invisible)
        }
        var tail: MermaidFlowchart.ArrowHead?
        if consume("<") {
            tail = .arrow
        } else if (hasPrefix("o") || hasPrefix("x")), let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                  next < text.endIndex, text[next] == "-" || text[next] == "=" {
            tail = text[index] == "o" ? .circle : .cross
            index = next
        }
        var link: Link
        if hasPrefix("-.") {
            guard let parsed = body(stroke: .dotted, open: "-.", textClose: ".-") else { index = start; return nil }
            link = parsed
        } else if hasPrefix("==") {
            guard let parsed = body(stroke: .thick, open: "==", textClose: "==") else { index = start; return nil }
            link = parsed
        } else if hasPrefix("--") {
            guard let parsed = body(stroke: .solid, open: "--", textClose: "--") else { index = start; return nil }
            link = parsed
        } else {
            index = start
            return nil
        }
        link.tail = tail
        skipSpaces()
        if peek == "|" {
            index = text.index(after: index)
            guard let close = text[index...].firstIndex(of: "|") else { return nil }
            var label = String(text[index..<close]).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 {
                label = String(label.dropFirst().dropLast())
            }
            link.label = label
            index = text.index(after: close)
        }
        return link
    }

    /// The link's stroke and head, after its optional tail. `-- text -->`
    /// has its text between `open` and `textClose`.
    private mutating func body(stroke: MermaidFlowchart.Stroke, open: String, textClose: String) -> Link? {
        let fill: Character = stroke == .thick ? "=" : "-"
        let start = index
        guard consume(open) else { return nil }
        if stroke == .dotted {
            while consume(".") {}
        }
        while consume(String(fill)) {}
        if let head = head() {
            return Link(stroke: stroke, head: head)
        }
        // `---`, `-.-`, `===`: no head. Exactly `--`/`==`/`-.` followed by
        // a space starts a text label.
        let consumed = text.distance(from: start, to: index)
        let isOpen = stroke == .dotted ? text[text.index(before: index)] == "-" && consumed > 2 : consumed > 2
        if isOpen {
            return Link(stroke: stroke)
        }
        guard let c = peek, c.isWhitespace else { return nil }
        // Text runs up to the closing part: `-->`, `---`, `.->`, `==>`, `===`.
        let rest = text[index...]
        guard let close = rest.range(of: textClose) else { return nil }
        let label = String(rest[rest.startIndex..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        index = close.upperBound
        while consume(String(fill)) {}
        let head = head()
        return Link(stroke: stroke, head: head, label: label.isEmpty ? nil : label.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    private mutating func head() -> MermaidFlowchart.ArrowHead? {
        if consume(">") { return .arrow }
        // `--o` / `--x` only when not the start of the next node's id.
        if let c = peek, c == "o" || c == "x" {
            let next = text.index(after: index)
            if next == text.endIndex || text[next].isWhitespace {
                index = next
                return c == "o" ? .circle : .cross
            }
        }
        return nil
    }
}
