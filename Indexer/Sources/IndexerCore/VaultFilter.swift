//
//  VaultFilter.swift
//  IndexerCore
//
//  Which vault folders are never indexed or published. Hidden folders
//  (`.obsidian`, `.trash`, …) and `node_modules` are always excluded; users
//  add their own folders with `--exclude` / `--exclude-file`.
//
//  Pattern rules (a subset of .gitignore, folders only):
//   - `Archive`          a folder named "Archive" at any depth;
//   - `/Archive`         only the top-level "Archive" folder;
//   - `Archive/2024`     that folder, relative to the vault root (a pattern
//                        containing "/" is always anchored to the root);
//   - `*` and `?` match within one path component; a trailing "/" is ignored.
//  Matching is case-insensitive and Unicode-normalized (NFC), like APFS.
//  Everything beneath an excluded folder is excluded.
//

import Foundation
import WikiShared

public struct VaultFilter: Sendable, Equatable {
    /// Directory names never indexed besides hidden ones: tool output that
    /// can hold thousands of Markdown files which are not notes.
    static let builtInDirectoryNames: Set<String> = ["node_modules"]

    struct Pattern: Sendable, Equatable {
        /// Lowercased NFC components; one component unless anchored.
        var components: [[Character]]
        var anchored: Bool
    }

    /// User patterns as given (normalized), for logging.
    public let patterns: [String]
    let compiled: [Pattern]

    public init() {
        patterns = []
        compiled = []
    }

    /// Throws `VaultFilter.InvalidPattern` for an empty pattern or one that
    /// contains "." / ".." components.
    public init(excluding patterns: [String]) throws {
        var normalized: [String] = []
        var compiled: [Pattern] = []
        for raw in patterns {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            let anchored = trimmed.hasPrefix("/")
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else {
                throw InvalidPattern(pattern: raw)
            }
            let pattern = Pattern(components: parts.map { Array($0.lowercased()) }, anchored: anchored || parts.count > 1)
            guard !compiled.contains(pattern) else { continue }
            compiled.append(pattern)
            normalized.append((pattern.anchored ? "/" : "") + parts.joined(separator: "/"))
        }
        self.patterns = normalized
        self.compiled = compiled
    }

    /// Reads patterns from a file: one per line, blank lines and lines
    /// starting with "#" are ignored.
    public static func patterns(fromFile url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// True if the folder at vault-relative `directoryPath` is excluded by
    /// itself (not by an ancestor; see `excludesPath(_:)`).
    public func excludesDirectory(_ directoryPath: String) -> Bool {
        let components = directoryPath.split(separator: "/")
        return !components.isEmpty && excludes(components[...], lowered: nil)
    }

    /// True if the folder at `directoryPath` or any folder above it is excluded.
    public func excludesPath(_ directoryPath: String) -> Bool {
        excludesAnyPrefix(of: directoryPath.split(separator: "/")[...])
    }

    /// True if any folder containing the file at `relativePath` is excluded.
    public func excludesAncestor(of relativePath: String) -> Bool {
        excludesAnyPrefix(of: relativePath.split(separator: "/").dropLast())
    }

    private func excludesAnyPrefix(of components: ArraySlice<Substring>) -> Bool {
        let lowered = compiled.isEmpty ? [] : components.map { Array($0.lowercased()) }
        for end in components.indices where excludes(components[..<(end + 1)], lowered: lowered) {
            return true
        }
        return false
    }

    /// `components` is a non-empty folder path; `lowered` (if given) holds
    /// the lowercased components of a path it is a prefix of.
    private func excludes(_ components: ArraySlice<Substring>, lowered: [[Character]]?) -> Bool {
        let name = components[components.endIndex - 1]
        if name.hasPrefix(".") || Self.builtInDirectoryNames.contains(String(name)) { return true }
        guard !compiled.isEmpty else { return false }
        let path = lowered.map { Array($0[..<components.count]) } ?? components.map { Array($0.lowercased()) }
        for pattern in compiled {
            if pattern.anchored {
                guard pattern.components.count == path.count else { continue }
                if zip(pattern.components, path).allSatisfy({ Self.glob($0, $1) }) { return true }
            } else if Self.glob(pattern.components[0], path[path.count - 1]) {
                return true
            }
        }
        return false
    }

    /// Wildcard match of one path component: `*` any run, `?` one character.
    static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var star = -1, resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                resume = t
                p += 1
            } else if star >= 0 {
                p = star + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    public struct InvalidPattern: Error, CustomStringConvertible {
        public var pattern: String
        public var description: String { "invalid exclude pattern \"\(pattern)\": must name a folder inside the vault" }
    }
}
