//
//  Models.swift
//  WikiViewerKit
//
//  Small value types returned by the repositories. None of them holds more
//  than one note body, and list types never include bodies.
//

import Foundation
import WikiShared

public struct NoteSummary: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var path: String

    public init(id: Int64, title: String, path: String) {
        self.id = id
        self.title = title
        self.path = path
    }

    public var folderPath: String { VaultPath.folder(of: path) }
}

public struct FolderSummary: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var parentID: Int64?
    public var name: String
    public var path: String
    public var noteCount: Int
    public var folderCount: Int
    public var assetCount: Int
}

public struct NoteDetail: Sendable, Equatable {
    public var id: Int64
    public var path: String
    public var title: String
    public var basename: String
    public var folderID: Int64
    public var modified: Date
    public var size: Int64
    public var properties: [Property]
    public var body: String
}

/// One frontmatter property, in source order.
public struct Property: Sendable, Hashable {
    public var key: String
    public var value: PropertyValue
}

public indirect enum PropertyValue: Sendable, Hashable {
    case text(String)
    case number(String)
    case bool(Bool)
    case null
    case list([PropertyValue])
    case object([Property])

    public var displayText: String {
        switch self {
        case .text(let s), .number(let s): s
        case .bool(let b): b ? "true" : "false"
        case .null: "—"
        case .list(let items): items.map(\.displayText).joined(separator: ", ")
        case .object(let props): props.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ")
        }
    }
}

public struct OutgoingLink: Sendable, Hashable {
    public var ordinal: Int
    public var kind: ViewerSchema.LinkKind
    public var isEmbed: Bool
    public var raw: String
    public var targetPath: String
    public var heading: String?
    public var blockID: String?
    public var display: String?
    public var targetNoteID: Int64?
    public var targetAssetID: Int64?

    public var isResolved: Bool { targetNoteID != nil || targetAssetID != nil }
}

public struct Backlink: Identifiable, Hashable, Sendable {
    public var id: Int64 { note.id }
    public var note: NoteSummary
    public var linkCount: Int
}

public struct TagSummary: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var noteCount: Int
}

public struct HeadingInfo: Sendable, Hashable {
    public var ordinal: Int
    public var level: Int
    public var text: String
    public var key: String
    public var line: Int
}

public struct AssetInfo: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var path: String
    public var name: String
    public var ext: String
    public var kind: ViewerSchema.AssetKind
    public var size: Int64
    public var blobSHA256: String?
    public var blobExt: String?
    public var blobSize: Int64?
    public var width: Int?
    public var height: Int?

    /// Relative path of the content-addressed blob, if one was shipped.
    public var blobRelativePath: String? {
        guard let blobSHA256, let blobExt else { return nil }
        return AssetBlobPath.relativePath(sha256: blobSHA256, fileExtension: blobExt)
    }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public enum Match: Sendable, Hashable {
        case title
        case alias(String)
        case tag(String)
        case path
        case content
    }

    public var id: Int64 { note.id }
    public var note: NoteSummary
    /// Snippet with highlighted ranges delimited by `SearchHit.highlightStart/End`.
    public var snippet: String?
    public var match: Match

    public static let highlightStart: Character = "\u{02}"
    public static let highlightEnd: Character = "\u{03}"
}

/// Keyset pagination cursor for title-ordered lists.
public struct TitleCursor: Sendable, Hashable {
    public var title: String
    public var id: Int64

    public init(after note: NoteSummary) {
        title = note.title
        id = note.id
    }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var hasMore: Bool
}

extension Page: Equatable where Item: Equatable {}
