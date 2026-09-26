//
//  NoteParser.swift
//  IndexerCore
//

import Foundation
import WikiShared
import Yams

/// Everything the builder stores for one note. Pure value; produced off the
/// database writer so parsing can run in parallel.
public struct ParsedNote: Sendable {
    public var title: String
    /// Frontmatter as a JSON array of `[key, value]` pairs, preserving the
    /// property order of the YAML source. nil if there is no frontmatter.
    public var frontmatterJSON: String?
    public var body: String
    public var aliases: [String]
    public var tags: [ParsedTag]
    /// Body links in scanner order, then wikilinks found in frontmatter
    /// string values (`line == -1`; their ranges are not body offsets).
    public var links: [ScannedLink]
    public var headings: [ScannedHeading]
    public var blockIDs: [ScannedBlockID]
    public var frontmatterError: String?
}

public struct ParsedTag: Sendable, Equatable {
    public var name: String
    public var source: ViewerSchema.TagSource
}

public enum NoteParser {
    /// Bumped when parsing changes what is stored for an unchanged file, so
    /// the builder re-parses every note once.
    /// 2: wikilinks in frontmatter values are stored as links.
    public static let version = 2

    public static func parse(path: String, text: String) -> ParsedNote {
        let split = Frontmatter.split(text)
        var properties: [(String, Node)] = []
        var frontmatterError: String?
        if let yaml = split.yaml, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let node = try Yams.compose(yaml: yaml) {
                    if case .mapping(let mapping) = node {
                        for (key, value) in mapping {
                            properties.append((key.string ?? String(describing: key), value))
                        }
                    } else {
                        frontmatterError = "frontmatter is not a mapping"
                    }
                }
            } catch {
                frontmatterError = "invalid YAML: \(error)"
            }
        }

        let scanned = ObsidianScanner().scan(split.body)
        let basename = VaultPath.basename(of: path)

        var title = basename
        var aliases: [String] = []
        var frontmatterTags: [String] = []
        for (key, value) in properties {
            switch key.lowercased() {
            case "title":
                if let s = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { title = s }
            case "aliases", "alias":
                // A scalar is one alias ("Smith, John" stays one alias).
                aliases.append(contentsOf: stringList(value, separators: []))
            case "tags", "tag":
                frontmatterTags.append(contentsOf: stringList(value, separators: [",", " "]))
            default:
                break
            }
        }

        // Tags: case-insensitive dedupe, first-seen spelling wins.
        var tags: [ParsedTag] = []
        var tagIndex: [String: Int] = [:]
        func addTag(_ raw: String, _ source: ViewerSchema.TagSource) {
            var name = raw.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("#") { name.removeFirst() }
            guard !name.isEmpty else { return }
            let key = VaultPath.matchKey(name)
            if let i = tagIndex[key] {
                if tags[i].source != source { tags[i].source = .both }
            } else {
                tagIndex[key] = tags.count
                tags.append(ParsedTag(name: name, source: source))
            }
        }
        frontmatterTags.forEach { addTag($0, .frontmatter) }
        scanned.tags.forEach { addTag($0.name, .inline) }

        var seenAliases = Set<String>()
        aliases = aliases.filter { !$0.isEmpty && seenAliases.insert(VaultPath.matchKey($0)).inserted }

        var seenBlocks = Set<String>()
        let blocks = scanned.blockIDs.filter { seenBlocks.insert($0.id).inserted }

        var frontmatterJSON: String?
        if !properties.isEmpty {
            frontmatterJSON = encodeProperties(properties)
            if frontmatterJSON == nil {
                frontmatterError = "frontmatter exceeds \(maximumFrontmatterJSONBytes) bytes when expanded (YAML aliases?); not stored"
            }
        }
        return ParsedNote(
            title: title,
            frontmatterJSON: frontmatterJSON,
            body: split.body,
            aliases: aliases,
            tags: tags,
            links: scanned.links + frontmatterLinks(properties.map(\.1)),
            headings: scanned.headings,
            blockIDs: blocks,
            frontmatterError: frontmatterError
        )
    }

    /// Upper bound on stored frontmatter. YAML aliases can expand a few
    /// hundred bytes into gigabytes ("billion laughs"); expansion stops here.
    static let maximumFrontmatterJSONBytes = 256 * 1024
    /// Upper bound on tags/aliases taken from one property.
    static let maximumListItems = 1000

    /// Upper bound on links taken from frontmatter.
    static let maximumFrontmatterLinks = 1000

    /// Wikilinks inside frontmatter string values, e.g. `up: "[[Home]]"` or
    /// `related: ["[[A]]", "[[B]]"]`. Obsidian links only wikilinks here;
    /// Markdown links in properties stay plain text.
    static func frontmatterLinks(_ values: [Node]) -> [ScannedLink] {
        var links: [ScannedLink] = []
        let scanner = ObsidianScanner()
        // YAML aliases can make the composed tree exponentially large; stop
        // after as many nodes as the stored JSON could hold.
        var budget = maximumFrontmatterJSONBytes
        func visit(_ node: Node, depth: Int) {
            guard depth < 32, budget > 0, links.count < maximumFrontmatterLinks else { return }
            budget -= 1
            switch node {
            case .scalar(let scalar):
                guard scalar.string.contains("[[") else { return }
                for var link in scanner.scan(scalar.string).links where link.kind == .wiki {
                    link.line = -1
                    links.append(link)
                }
            case .sequence(let seq):
                for item in seq { visit(item, depth: depth + 1) }
            case .mapping(let mapping):
                for (_, value) in mapping { visit(value, depth: depth + 1) }
            case .alias:
                break
            }
        }
        for value in values { visit(value, depth: 0) }
        return Array(links.prefix(maximumFrontmatterLinks))
    }

    /// A YAML string or sequence → list of strings.
    static func stringList(_ node: Node, separators: Set<Character>) -> [String] {
        switch node {
        case .scalar(let scalar):
            guard !separators.isEmpty else {
                let v = scalar.string.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? [] : [v]
            }
            return scalar.string.split(whereSeparator: { separators.contains($0) })
                .prefix(maximumListItems)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case .sequence(let seq):
            return seq.prefix(maximumListItems).compactMap { item in
                guard case .scalar(let s) = item else { return nil }
                let v = s.string.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        default:
            return []
        }
    }

    /// nil if the encoded JSON would exceed `maximumFrontmatterJSONBytes`.
    static func encodeProperties(_ properties: [(String, Node)]) -> String? {
        var budget = maximumFrontmatterJSONBytes
        var out = "["
        for (i, (key, value)) in properties.enumerated() {
            if i > 0 { out += "," }
            out += "["
            out += jsonString(key)
            out += ","
            guard let v = jsonValue(value, depth: 0, budget: &budget) else { return nil }
            out += v
            out += "]"
        }
        out += "]"
        return out.utf8.count <= maximumFrontmatterJSONBytes ? out : nil
    }

    static func jsonValue(_ node: Node, depth: Int, budget: inout Int) -> String? {
        guard depth < 32 else { return "null" }
        guard budget > 0 else { return nil }
        let result: String?
        switch node {
        case .scalar(let scalar):
            var plain: String?
            if scalar.style == .plain {
                switch node.tag.description {
                case "tag:yaml.org,2002:null": plain = "null"
                case "tag:yaml.org,2002:bool": plain = node.bool.map { $0 ? "true" : "false" }
                case "tag:yaml.org,2002:int": plain = node.int.map { String($0) }
                case "tag:yaml.org,2002:float": plain = node.float.flatMap { $0.isFinite ? String($0) : nil }
                default: break
                }
            }
            result = plain ?? jsonString(scalar.string)
        case .sequence(let seq):
            var parts: [String] = []
            for item in seq {
                guard let v = jsonValue(item, depth: depth + 1, budget: &budget) else { return nil }
                parts.append(v)
            }
            result = "[" + parts.joined(separator: ",") + "]"
        case .mapping(let mapping):
            var parts: [String] = []
            for (key, value) in mapping {
                guard let v = jsonValue(value, depth: depth + 1, budget: &budget) else { return nil }
                parts.append(jsonString(key.string ?? "") + ":" + v)
            }
            result = "{" + parts.joined(separator: ",") + "}"
        case .alias:
            result = "null"
        }
        if let result {
            budget -= result.utf8.count
            if budget < 0 { return nil }
        }
        return result
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
