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
    /// Modification time in nanoseconds since 1970, exact for keyset
    /// paging; only listings ordered by it fill this in.
    public var modifiedNanoseconds: Int64?

    public init(id: Int64, title: String, path: String, modifiedNanoseconds: Int64? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    public var modified: Date? {
        modifiedNanoseconds.map { Date(timeIntervalSince1970: Double($0) / 1e9) }
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
    /// Line in the body (0-based); -1 for a link in a frontmatter value.
    public var line: Int = 0

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

/// One level of the tag hierarchy (`project`, `project/alpha`).
public struct TagNode: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Full tag name, e.g. `project/alpha`.
    public var name: String
    /// Last component, e.g. `alpha`.
    public var component: String
    /// Notes carrying exactly this tag; 0 if only nested tags are used.
    public var noteCount: Int
    public var hasChildren: Bool
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

/// Order of the notes listed in one folder.
public enum NoteOrder: String, Sendable, CaseIterable, Codable {
    /// Title A→Z (notes_folder index).
    case titleAscending
    /// Title Z→A (notes_folder index read backwards): newest first for
    /// date-named notes such as daily notes.
    case titleDescending
    /// Most recently modified first. No index serves this order, so it is
    /// only applied to folders with at most
    /// `FolderRepository.maxNotesSortedByModified` notes.
    case modifiedNewest
}

/// Keyset pagination cursor for folder listings in any `NoteOrder`.
public struct NoteCursor: Sendable, Hashable {
    public var title: String
    public var id: Int64
    public var modifiedNanoseconds: Int64

    public init(after note: NoteSummary) {
        title = note.title
        id = note.id
        modifiedNanoseconds = note.modifiedNanoseconds ?? 0
    }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var hasMore: Bool
}

extension Page: Equatable where Item: Equatable {}
