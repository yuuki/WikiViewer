//
//  VaultPath.swift
//  WikiShared
//

import Foundation

/// Helpers for vault-relative paths ("folder/sub/Note.md").
///
/// Vault-relative paths always use "/" separators, never start with "/",
/// and never contain "." or ".." components. They are stored in Unicode NFC
/// because macOS file systems may hand back NFD names.
public enum VaultPath {
    /// Normalizes a path to NFC and "/" separators, and strips leading "./"
    /// and "/". Returns nil if the path escapes the root ("..") or is empty.
    public static func normalizeRelative(_ path: String) -> String? {
        let nfc = path.precomposedStringWithCanonicalMapping
        var components: [Substring] = []
        for component in nfc.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// True if `path` is already a normalized, safe relative path.
    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// "a/b/Note.md" → "a/b"; "Note.md" → "".
    public static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// "a/b/Note.md" → "Note.md".
    public static func fileName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// "a/b/Note.md" → "Note"; "a/b/image.PNG" → "image".
    public static func basename(of path: String) -> String {
        let name = fileName(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Lowercased extension without the dot; "" if there is none.
    public static func fileExtension(of path: String) -> String {
        let name = fileName(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Joins a folder and a relative reference, resolving "." and "..".
    public static func join(folder: String, _ relative: String) -> String? {
        normalizeRelative(folder.isEmpty ? relative : folder + "/" + relative)
    }

    /// Case- and normalization-insensitive key used for link matching.
    public static func matchKey(_ string: some StringProtocol) -> String {
        String(string).precomposedStringWithCanonicalMapping.lowercased()
    }
}
