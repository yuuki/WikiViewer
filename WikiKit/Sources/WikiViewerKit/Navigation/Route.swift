//
//  Route.swift
//  WikiViewerKit
//
//  Where the viewer can go, and how a macOS window decides where a route
//  opens. Kept here, below the UI, so that both are tested with the rest of
//  the viewer's logic.
//

import Foundation

/// Navigation destinations. Notes and folders are addressed by vault path,
/// not database id, so a navigation stack survives a generation switch.
public enum Route: Hashable, Codable, Sendable {
    case folder(path: String)
    case note(path: String, anchor: NoteAnchor?)
    /// An Obsidian Bases file (`.base`).
    case base(path: String)
    case tag(name: String)
    case missing(target: String)
    case search
    case tags
    case recents
    /// Requests to the Mac's Claude and their answers.
    case requests
    /// What changed in the vault since the reader last looked.
    case digest
    /// The Graph tab's cluster overview.
    case graph
    /// One cluster; `focus` is a note path to select on arrival.
    case graphCluster(id: Int64, focus: String?)
    case localGraph(path: String)
}

public struct NoteAnchor: Hashable, Codable, Sendable {
    public var heading: String?
    public var blockID: String?
    /// Text to find in the note (a search match), highlighted on arrival.
    public var text: String?

    public init(heading: String? = nil, blockID: String? = nil, text: String? = nil) {
        self.heading = heading
        self.blockID = blockID
        self.text = text
    }
}

/// The app's sections: tabs on iOS, the sidebar on macOS.
public enum AppTab: String, Hashable, Codable, CaseIterable, Sendable {
    case files, search, tags, graph
}

extension Route {
    /// A list to browse (folder, tag, tag list, search, recent notes), as
    /// opposed to a document to read. On macOS lists open in the content
    /// column and documents in the detail column.
    public var isList: Bool {
        switch self {
        case .folder, .tag, .tags, .search, .recents, .requests, .digest: true
        case .note, .base, .missing, .graph, .graphCluster, .localGraph: false
        }
    }

    /// A folder with its parents, root first, so going back walks up the
    /// tree. Empty for the vault root.
    public static func folderChain(_ path: String) -> [Route] {
        let components = path.split(separator: "/").map(String.init)
        return components.indices.map { .folder(path: components[...$0].joined(separator: "/")) }
    }
}

/// What a macOS window does with a route, given where it was opened from:
/// the content column (lists) or a document (or the sidebar).
public enum RouteDispatch: Equatable, Sendable {
    /// Push onto the current section's list stack.
    case pushList(Route)
    /// Switch to a section and show these lists there (empty: its root).
    case showList(AppTab, [Route])
    /// Open in the detail column.
    case openDocument(Route)

    public enum Origin: Sendable {
        case list, document
    }

    public static func dispatch(_ route: Route, from origin: Origin) -> RouteDispatch {
        guard route.isList else { return .openDocument(route) }
        if origin == .list { return .pushList(route) }
        switch route {
        case .folder(let path): return .showList(.files, Route.folderChain(path))
        case .recents: return .showList(.files, [.recents])
        case .requests: return .showList(.files, [.requests])
        case .digest: return .showList(.files, [.digest])
        case .tag(let name): return .showList(.tags, [.tag(name: name)])
        case .tags: return .showList(.tags, [])
        case .search: return .showList(.search, [])
        case .note, .base, .missing, .graph, .graphCluster, .localGraph: return .openDocument(route)
        }
    }
}
