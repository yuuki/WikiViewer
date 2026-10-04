//
//  Provenance.swift
//  WikiShared
//
//  Who wrote a note: the reader (in Obsidian) or Claude (the vault's wiki
//  tooling). The indexer reads only the vault, so the answer comes from the
//  note itself, in this order:
//
//  1. an explicit frontmatter field `author_kind` (or `provenance`):
//     "claude", "llm", "ai", "agent" → Claude; "human", "me" → the reader;
//  2. an `address` field of the form `c-NNNNNN`, which only the vault's
//     wiki tooling allocates (wiki-page-write.py);
//  3. the folder: notes under `wiki/` are the LLM wiki layer;
//  4. otherwise the reader.
//
//  It describes the note, not each edit: a wiki page the reader touched in
//  Obsidian still counts as Claude's.
//

public enum Provenance {
    public enum Author: Int, Sendable, Codable, CaseIterable {
        case human = 0
        case claude = 1
    }

    /// Folder of the LLM wiki layer.
    public static let wikiFolder = "wiki/"

    static let explicitKeys = ["author_kind", "provenance"]
    static let claudeWords = ["claude", "llm", "ai", "agent", "machine"]
    static let humanWords = ["human", "me", "person", "manual"]

    /// `fields`: the note's top-level frontmatter values as text.
    public static func author(path: String, fields: [String: String]) -> Author {
        for key in explicitKeys {
            guard let value = fields[key]?.lowercased() else { continue }
            if claudeWords.contains(where: { value.contains($0) }) { return .claude }
            if humanWords.contains(where: { value.contains($0) }) { return .human }
        }
        if let address = fields["address"], isWikiAddress(address) { return .claude }
        return path.hasPrefix(wikiFolder) ? .claude : .human
    }

    /// "c-000123": the wiki tooling's page address.
    static func isWikiAddress(_ value: String) -> Bool {
        guard value.hasPrefix("c-") else { return false }
        let digits = value.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
