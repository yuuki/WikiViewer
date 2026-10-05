//
//  LearningPath.swift
//  WikiViewerKit
//
//  A learning path note (#35): existing notes in the order to read them,
//  written by Claude on request (`type: path` in the frontmatter, usually
//  under `wiki/paths/`). The steps are the note's top-level numbered list
//  items; a step's note is the first resolved link on its line. A step
//  without one is a gap: material the vault does not have yet (a bridging
//  source to find, wiki-gap's candidates).
//

import Foundation

public struct LearningPath: Sendable, Equatable {
    public struct Step: Sendable, Equatable, Identifiable {
        /// The step's line in the body.
        public var line: Int
        /// The list number as written.
        public var number: Int
        /// The line as readable text (links shown as their labels).
        public var text: String
        /// What the step says besides its note: why it is here, or for a
        /// gap, what is missing ("橋渡し:" / "Bridge:" dropped).
        public var detail: String
        public var noteID: Int64?
        public var heading: String?

        public var id: Int { line }
        /// No note in the vault yet: a bridge to find.
        public var isGap: Bool { noteID == nil }
    }

    public var steps: [Step]

    public static let maximumSteps = 100
    /// Frontmatter `type` values of a learning path.
    static let types: Set<String> = ["path", "learning-path"]

    public static func isPath(properties: [Property]) -> Bool {
        guard let type = properties.first(where: { $0.key == "type" })?.value else { return false }
        if case .text(let value) = type { return types.contains(value.lowercased()) }
        return false
    }

    /// The steps of a path note, or nil if it has no numbered list.
    /// `links` are the note's outgoing links (with their lines).
    public static func parse(body: String, links: [OutgoingLink]) -> LearningPath? {
        var linksByLine: [Int: [OutgoingLink]] = [:]
        for link in links where !link.isEmbed && link.line >= 0 {
            linksByLine[link.line, default: []].append(link)
        }
        var steps: [Step] = []
        var inFence = false
        // Split on scalars, as the scanner counts lines ("\r\n" is one Character).
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            // Top-level items only: nested ones explain a step.
            guard !inFence, !line.hasPrefix("  "), !line.hasPrefix("\t"),
                  let (number, rest) = numberedItem(trimmed) else { continue }
            let target = linksByLine[index]?.first { $0.targetNoteID != nil }
            steps.append(Step(line: index, number: number, text: readable(rest), detail: detail(of: rest, without: target?.raw),
                              noteID: target?.targetNoteID, heading: target?.heading))
            if steps.count == maximumSteps { break }
        }
        return steps.isEmpty ? nil : LearningPath(steps: steps)
    }

    /// "12. rest" or "12) rest" → (12, "rest").
    static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let after = line.dropFirst(digits.count)
        guard let marker = after.first, marker == "." || marker == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let gapPrefixes = ["橋渡し:", "橋渡し：", "Bridge:", "Gap:"]

    static func detail(of item: String, without raw: String?) -> String {
        var rest = item
        // `raw` is the link's target text: remove the wikilink around it.
        if let raw, let wiki = try? Regex(#"!?\[\[([^\]|]*)(?:\|[^\]]*)?\]\]"#),
           let match = rest.matches(of: wiki).first(where: { $0.output[1].substring.map(String.init) == raw }) {
            rest.removeSubrange(match.range)
        }
        var text = readable(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        for prefix in gapPrefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–-:：*"))
        return text.trimmingCharacters(in: separators)
    }

    /// Shows links as their text: "[[a/b#c|Label]]" → "Label", "[[a/b]]" → "b",
    /// "[text](url)" → "text"; drops emphasis markers.
    public static func readable(_ line: String) -> String {
        var text = line
        if let wiki = try? Regex(#"!?\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"#) {
            text = text.replacing(wiki) { match in
                if let label = match.output[2].substring, !label.isEmpty { return String(label) }
                let target = match.output[1].substring.map(String.init) ?? ""
                let page = target.split(separator: "#").first.map(String.init) ?? target
                return page.split(separator: "/").last.map(String.init) ?? page
            }
        }
        if let markdown = try? Regex(#"\[([^\]]*)\]\([^)]*\)"#) {
            text = text.replacing(markdown) { String($0.output[1].substring ?? "") }
        }
        // Not "__": source names use it ("@2026__PVLDB__Title").
        return text.replacingOccurrences(of: "**", with: "")
    }
}
