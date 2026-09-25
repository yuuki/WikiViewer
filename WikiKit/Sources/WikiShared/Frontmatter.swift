//
//  Frontmatter.swift
//  WikiShared
//

/// Splits YAML frontmatter from a note.
///
/// Obsidian recognizes frontmatter only when the file starts with a line
/// containing exactly `---` and a later line containing exactly `---`.
public enum Frontmatter {
    public struct Split: Sendable, Equatable {
        /// YAML text between the delimiters, or nil if there is none.
        public var yaml: String?
        /// The Markdown body after the closing delimiter.
        public var body: String
    }

    public static func split(_ text: String) -> Split {
        var content = Substring(text)
        if content.hasPrefix("\u{FEFF}") { content = content.dropFirst() }
        // Lines are split on "\n" bytes, not Characters: in Swift "\r\n" is a
        // single Character, so Character-based splitting misses CRLF files.
        let utf8 = content.utf8
        guard let firstNewline = utf8.firstIndex(of: 0x0A), isDelimiter(content[content.startIndex..<firstNewline]) else {
            return Split(yaml: nil, body: String(content))
        }
        let yamlStart = utf8.index(after: firstNewline)
        var lineStart = yamlStart
        while lineStart < content.endIndex {
            let newline = utf8[lineStart...].firstIndex(of: 0x0A) ?? content.endIndex
            if isDelimiter(content[lineStart..<newline]) {
                var yaml = content[yamlStart..<lineStart]
                while yaml.utf8.last == 0x0A || yaml.utf8.last == 0x0D { yaml = yaml.dropLast() }
                let body = newline < content.endIndex ? String(content[utf8.index(after: newline)...]) : ""
                return Split(yaml: String(yaml), body: body)
            }
            guard newline < content.endIndex else { break }
            lineStart = utf8.index(after: newline)
        }
        // Unterminated frontmatter: treat the whole file as body.
        return Split(yaml: nil, body: String(content))
    }

    private static func isDelimiter(_ line: Substring) -> Bool {
        var bytes = Array(line.utf8)
        while let last = bytes.last, last == 0x0D || last == 0x20 || last == 0x09 { bytes.removeLast() }
        return bytes == Array("---".utf8)
    }
}
