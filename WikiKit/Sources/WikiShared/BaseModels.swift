//
//  BaseModels.swift
//  WikiShared
//
//  What the indexer stores for an Obsidian Bases file (`.base`) and the
//  viewer reads back: the views of the base (`bases.definition`) and the
//  value of each cell (`base_cells.cells`). The indexer evaluates filters,
//  formulas, sorting and grouping; the viewer only displays the result.
//

import Foundation

/// The evaluated shape of one `.base` file.
public struct BaseDocument: Codable, Sendable, Hashable {
    public var views: [View]
    /// Why the base could not be evaluated (invalid YAML, unsupported
    /// expression); views are then empty or partial.
    public var error: String?

    public init(views: [View], error: String? = nil) {
        self.views = views
        self.error = error
    }

    public struct View: Codable, Sendable, Hashable {
        /// `table`, `list`, `cards`, … as written in the file.
        public var type: String
        public var name: String
        /// Displayed columns in order; `file.name` is the note itself.
        public var columns: [Column]
        /// True if rows are grouped (`base_groups` holds the headers).
        public var grouped: Bool
        public var rowCount: Int

        public init(type: String, name: String, columns: [Column], grouped: Bool, rowCount: Int) {
            self.type = type
            self.name = name
            self.columns = columns
            self.grouped = grouped
            self.rowCount = rowCount
        }
    }

    public struct Column: Codable, Sendable, Hashable {
        /// Property id as in the file: `status`, `note.status`,
        /// `file.mtime`, `formula.topic_tags`.
        public var id: String
        /// `displayName` from the file's `properties`, if any.
        public var displayName: String?

        public init(id: String, displayName: String?) {
            self.id = id
            self.displayName = displayName
        }

        /// The note's own name column, shown as the row title.
        public var isFileName: Bool { id == "file.name" || id == "file.basename" }

        /// `displayName`, else the id without its `note.`/`formula.`/`file.` prefix.
        public var label: String {
            if let displayName, !displayName.isEmpty { return displayName }
            for prefix in ["note.", "formula.", "file."] where id.hasPrefix(prefix) {
                return String(id.dropFirst(prefix.count))
            }
            return id
        }
    }
}

/// One evaluated cell, JSON-encoded compactly: a string, number or boolean
/// as itself, a list as an array, `{"d": "2026-09-27"}` for a date and
/// `{"l": "Title", "p": "path/Note.md"}` for a link (`p` absent when
/// unresolved).
public indirect enum BaseCell: Sendable, Hashable, Codable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(String)
    case link(display: String, path: String?)
    case list([BaseCell])

    public var displayText: String {
        switch self {
        case .text(let s), .date(let s): s
        case .number(let n): Self.format(n)
        case .bool(let b): b ? "true" : "false"
        case .link(let display, _): display
        case .list(let items): items.map(\.displayText).joined(separator: ", ")
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .text(let s), .date(let s): s.isEmpty
        case .list(let items): items.allSatisfy(\.isEmpty)
        default: false
        }
    }

    /// Integers without a fraction, others as Swift prints them.
    public static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    private enum Keys: String, CodingKey {
        case d, l, p
    }

    public init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [BaseCell] = []
            while !array.isAtEnd { items.append(try array.decode(BaseCell.self)) }
            self = .list(items)
            return
        }
        if let object = try? decoder.container(keyedBy: Keys.self) {
            if let date = try object.decodeIfPresent(String.self, forKey: .d) {
                self = .date(date)
                return
            }
            if let display = try object.decodeIfPresent(String.self, forKey: .l) {
                self = .link(display: display, path: try object.decodeIfPresent(String.self, forKey: .p))
                return
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown cell object"))
        }
        let single = try decoder.singleValueContainer()
        if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? single.decode(Double.self) {
            self = .number(n)
        } else {
            self = .text(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .number(let n):
            var c = encoder.singleValueContainer()
            try c.encode(n.isFinite ? n : 0)
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .date(let s):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(s, forKey: .d)
        case .link(let display, let path):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(display, forKey: .l)
            try c.encodeIfPresent(path, forKey: .p)
        case .list(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        }
    }
}
