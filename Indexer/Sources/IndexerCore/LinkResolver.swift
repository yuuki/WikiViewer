//
//  LinkResolver.swift
//  IndexerCore
//
//  Link resolution semantics. Pure functions; the builder feeds them
//  candidate rows looked up by `target_key` (an indexed column), so resolving
//  one link never scans the notes table.
//
//  Rules (documented in ARCHITECTURE.md, "Link resolution"):
//   1. Empty path (`[[#Heading]]`, `[x](#h)`) → the source note.
//   2. The target is an asset if its extension is a known attachment type
//      other than `.md`; otherwise it is a note (".md" is optional).
//   3. Candidates share the target's file name (case- and
//      Unicode-normalization-insensitive).
//   4. Preference order:
//      a. relative path from the source folder (Markdown links, and
//         wikilinks starting with "./" or "../");
//      b. exact vault-root path;
//      c. if the target contains "/": candidates whose path ends with
//         "/<target>"; if none match, the link is unresolved;
//      d. otherwise any candidate.
//      Ties: same folder as the source, then fewest path components, then
//      shortest path, then lexicographic path — fully deterministic.
//   5. Aliases never resolve links (Obsidian inserts `[[file|alias]]`).
//

import WikiShared

public enum ResolutionTarget: Sendable, Equatable {
    case sameNote
    case note(key: String, path: String, explicitPath: Bool, relativePath: String?)
    case asset(key: String, path: String, explicitPath: Bool, relativePath: String?)
    case invalid

    public var key: String {
        switch self {
        case .sameNote, .invalid: ""
        case .note(let key, _, _, _), .asset(let key, _, _, _): key
        }
    }
}

public struct ResolutionCandidate: Sendable, Equatable {
    public var id: Int64
    /// Vault-relative path (with extension).
    public var path: String

    public init(id: Int64, path: String) {
        self.id = id
        self.path = path
    }
}

public enum LinkResolver {
    public static func classify(kind: ViewerSchema.LinkKind, targetPath: String, sourcePath: String) -> ResolutionTarget {
        let trimmed = targetPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .sameNote }
        let sourceFolder = VaultPath.folder(of: sourcePath)

        let isRelativeSyntax = trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
        let relative: String? = (kind == .markdown || isRelativeSyntax)
            ? VaultPath.join(folder: sourceFolder, trimmed)
            : nil
        // Vault-rooted interpretation ("/a/b" and "a/b" are the same).
        let rooted = isRelativeSyntax ? relative : VaultPath.normalizeRelative(trimmed)
        guard let path = rooted ?? relative else { return .invalid }

        let ext = VaultPath.fileExtension(of: path)
        if ext != "md", ViewerSchema.AssetKind.forExtension(ext) != nil {
            return .asset(
                key: VaultPath.matchKey(VaultPath.fileName(of: path)),
                path: path,
                explicitPath: path.contains("/"),
                relativePath: relative
            )
        }
        let noteName = stripMarkdownExtension(path)
        return .note(
            key: VaultPath.matchKey(VaultPath.fileName(of: noteName)),
            path: noteName,
            explicitPath: noteName.contains("/"),
            relativePath: relative.map(stripMarkdownExtension)
        )
    }

    /// Chooses the target among candidates that share the target's key.
    public static func choose(_ target: ResolutionTarget, candidates: [ResolutionCandidate], sourcePath: String) -> Int64? {
        guard !candidates.isEmpty else { return nil }
        let isNote: Bool
        let path: String
        let explicit: Bool
        let relative: String?
        switch target {
        case .sameNote, .invalid:
            return nil
        case .note(_, let p, let e, let r):
            (isNote, path, explicit, relative) = (true, p, e, r)
        case .asset(_, let p, let e, let r):
            (isNote, path, explicit, relative) = (false, p, e, r)
        }
        func comparable(_ c: ResolutionCandidate) -> String {
            VaultPath.matchKey(isNote ? stripMarkdownExtension(c.path) : c.path)
        }
        if let relative {
            let key = VaultPath.matchKey(relative)
            if let hit = candidates.first(where: { comparable($0) == key }) { return hit.id }
        }
        let targetKey = VaultPath.matchKey(path)
        let exact = candidates.filter { comparable($0) == targetKey }
        if !exact.isEmpty { return best(exact, sourcePath: sourcePath) }
        if explicit {
            let suffix = "/" + targetKey
            let suffixed = candidates.filter { comparable($0).hasSuffix(suffix) }
            return suffixed.isEmpty ? nil : best(suffixed, sourcePath: sourcePath)
        }
        return best(candidates, sourcePath: sourcePath)
    }

    static func best(_ candidates: [ResolutionCandidate], sourcePath: String) -> Int64? {
        let sourceFolder = VaultPath.folder(of: sourcePath)
        return candidates.min { a, b in
            let aSame = VaultPath.folder(of: a.path) == sourceFolder
            let bSame = VaultPath.folder(of: b.path) == sourceFolder
            if aSame != bSame { return aSame }
            let aDepth = a.path.split(separator: "/").count
            let bDepth = b.path.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }?.id
    }

    static func stripMarkdownExtension(_ path: String) -> String {
        VaultPath.fileExtension(of: path) == "md" ? String(path.dropLast(3)) : path
    }
}
