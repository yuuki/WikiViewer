//
//  LinkTarget.swift
//  WikiShared
//

import Foundation

/// The parsed parts of an Obsidian link target.
///
/// `[[folder/Note#Heading|Label]]` → path "folder/Note", heading "Heading",
/// display "Label". `[[Note#^abc]]` → blockID "abc". `[[#Heading]]` has an
/// empty path and refers to the note containing the link.
public struct LinkTarget: Sendable, Hashable {
    /// Link path as written (after percent-decoding for Markdown links).
    /// Empty for same-note links.
    public var path: String
    /// Heading subpath, possibly nested ("A#B"), without the leading "#".
    public var heading: String?
    /// Block identifier without the leading "^".
    public var blockID: String?
    /// Display text / alias, or for image embeds the size spec ("300x200").
    public var display: String?

    public init(path: String, heading: String? = nil, blockID: String? = nil, display: String? = nil) {
        self.path = path
        self.heading = heading
        self.blockID = blockID
        self.display = display
    }

    /// Parses the inner text of a wikilink or embed (between `[[` and `]]`).
    public static func parseWiki(_ inner: String) -> LinkTarget {
        // In tables Obsidian users escape the pipe as "\|".
        let unescaped = inner.replacingOccurrences(of: "\\|", with: "|")
        var linkPart = Substring(unescaped)
        var display: String?
        if let pipe = unescaped.firstIndex(of: "|") {
            linkPart = unescaped[..<pipe]
            display = String(unescaped[unescaped.index(after: pipe)...])
        }
        var target = splitSubpath(String(linkPart))
        target.path = target.path.trimmingCharacters(in: .whitespaces)
        target.display = display
        return target
    }

    /// Parses a Markdown link destination such as `Folder/My%20Note.md#Heading`.
    public static func parseMarkdown(destination: String) -> LinkTarget {
        var dest = destination.trimmingCharacters(in: .whitespaces)
        if dest.hasPrefix("<") && dest.hasSuffix(">") && dest.count >= 2 {
            dest = String(dest.dropFirst().dropLast())
        }
        var target = splitSubpath(dest)
        target.path = target.path.removingPercentEncoding ?? target.path
        if let heading = target.heading {
            target.heading = heading.removingPercentEncoding ?? heading
        }
        return target
    }

    private static func splitSubpath(_ link: String) -> LinkTarget {
        guard let hash = link.firstIndex(of: "#") else {
            return LinkTarget(path: link)
        }
        let path = String(link[..<hash])
        let subpath = String(link[link.index(after: hash)...])
        if subpath.hasPrefix("^") {
            return LinkTarget(path: path, blockID: String(subpath.dropFirst()))
        }
        return LinkTarget(path: path, heading: subpath.isEmpty ? nil : subpath)
    }

    /// True if a Markdown link destination refers to something outside the
    /// vault (has a URI scheme or is protocol-relative).
    public static func isExternal(markdownDestination dest: String) -> Bool {
        if dest.hasPrefix("//") { return true }
        guard let colon = dest.firstIndex(of: ":") else { return false }
        let scheme = dest[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }
}

/// Normalization used to compare heading text from a link with heading text
/// in a note. Obsidian strips characters that are not allowed in link
/// subpaths, so we compare only letters and numbers, case-insensitively.
public enum HeadingKey {
    public static func make(_ text: some StringProtocol) -> String {
        var out = String.UnicodeScalarView()
        for scalar in String(text).precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            let props = scalar.properties
            if props.isAlphabetic || props.numericType != nil {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// For nested subpaths "A#B#C" Obsidian navigates to the last heading.
    public static func lastComponent(of heading: String) -> Substring {
        guard let hash = heading.lastIndex(of: "#") else { return Substring(heading) }
        return heading[heading.index(after: hash)...]
    }
}
