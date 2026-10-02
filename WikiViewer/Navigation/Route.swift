//
//  Route.swift
//  WikiViewer
//

import SwiftUI
import WikiShared
#if os(macOS)
import AppKit
#endif
import WikiViewerKit

/// Navigation destinations. Notes and folders are addressed by vault path,
/// not database id, so a navigation stack survives a generation switch.
enum Route: Hashable, Codable {
    case folder(path: String)
    case note(path: String, anchor: Anchor?)
    /// An Obsidian Bases file (`.base`).
    case base(path: String)
    case tag(name: String)
    case missing(target: String)
    case search
    case tags
    case recents
    /// The Graph tab's cluster overview.
    case graph
    /// One cluster; `focus` is a note path to select on arrival.
    case graphCluster(id: Int64, focus: String?)
    case localGraph(path: String)
}

extension Route {
    /// A list to browse (folder, tag, tag list, search, recent notes), as
    /// opposed to a document to read. On macOS lists open in the content
    /// column and documents in the detail column.
    var isList: Bool {
        switch self {
        case .folder, .tag, .tags, .search, .recents: true
        case .note, .base, .missing, .graph, .graphCluster, .localGraph: false
        }
    }
}

/// Where a route opens. `automatic` is the current tab or column, or on
/// macOS a new tab (⌘-click) or window (⌥⌘-click) when those keys are held.
enum RouteTarget {
    case automatic, newTab, newWindow
}

extension RouteTarget {
    /// `automatic`, or on macOS the target the modifier keys of the event
    /// being handled ask for. Read it while handling the click: a task that
    /// opens the route later no longer sees that event.
    @MainActor
    static var fromCurrentEvent: RouteTarget {
        #if os(macOS)
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { return flags.contains(.option) ? .newWindow : .newTab }
        #endif
        return .automatic
    }
}

/// Opens a route from a screen: iOS pushes it onto the tab's stack; macOS
/// sends lists to the content column and documents to the detail column
/// (MacRootView). Screens call this instead of pushing themselves.
struct OpenRouteAction {
    let handler: @MainActor (Route, RouteTarget) -> Void

    @MainActor
    func callAsFunction(_ route: Route, in target: RouteTarget = .automatic) {
        handler(route, target)
    }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { route, _ in
        assertionFailure("No openRoute for \(route)")
    }
}

struct Anchor: Hashable, Codable {
    var heading: String?
    var blockID: String?
    /// Text to find in the note (a search match), highlighted on arrival.
    var text: String?
}

/// One stack of screens with browser-like history: going back keeps the
/// screens left for going forward again, until something new is opened.
@Observable
final class NavigationModel {
    var path: [Route] = [] {
        didSet {
            guard !adjusting else { return }
            if path.count < oldValue.count, Array(oldValue.prefix(path.count)) == path {
                // Popped, by back() or the stack's own back button.
                forwardPath += oldValue[path.count...].reversed()
            } else {
                forwardPath.removeAll()
            }
        }
    }
    /// Screens to go forward to, the next one last.
    private(set) var forwardPath: [Route] = []
    @ObservationIgnored private var adjusting = false
    /// The note on top of this stack, set by NoteView while it is showing.
    var note: NoteFocus?

    /// Bounds a stack that grows with every note opened (macOS detail column).
    static let maxDepth = 100

    func push(_ route: Route) {
        path.append(route)
        if path.count > Self.maxDepth {
            adjust { path.removeFirst(path.count - Self.maxDepth) }
        }
    }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardPath.isEmpty }

    func back() {
        _ = path.popLast()
    }

    func forward() {
        guard let route = forwardPath.popLast() else { return }
        adjust { path.append(route) }
    }

    /// Replaces the whole stack, e.g. to show a folder with its parents.
    func reset(to routes: [Route]) {
        path = routes
    }

    private func adjust(_ change: () -> Void) {
        adjusting = true
        change()
        adjusting = false
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .folder(let path): FolderView(path: path)
        case .note(let path, let anchor): NoteView(path: path, anchor: anchor)
        case .base(let path): BaseView(path: path)
        case .tag(let name): TagNotesView(name: name)
        case .missing(let target): MissingNoteView(target: target)
        case .search: SearchView()
        case .tags: TagsView()
        case .recents: RecentNotesView()
        case .graph: GraphOverviewView()
        case .graphCluster(let id, let focus): ClusterGraphView(id: id, focus: focus)
        case .localGraph(let path): LocalGraphView(path: path)
        }
    }
}

/// Handles taps on in-note links (wikilinks, tags, assets, external URLs).
struct LinkRouter {
    let session: LibrarySession
    let openRoute: OpenRouteAction
    let currentNoteID: Int64?
    let scrollTo: (Anchor) -> Void
    /// Presents an attachment; bases are pushed as a screen instead.
    let openAsset: (AssetInfo) -> Void

    func handle(_ url: URL) -> OpenURLAction.Result {
        guard let action = WikiLinkAction(url: url) else { return .discarded }
        let opening = RouteTarget.fromCurrentEvent
        switch action {
        case .external:
            return .systemAction
        case .note(let id, let heading, let blockID):
            let anchor = (heading != nil || blockID != nil) ? Anchor(heading: heading, blockID: blockID) : nil
            if id == currentNoteID {
                if let anchor { scrollTo(anchor) }
                return .handled
            }
            Task {
                if let summary = try? await session.notes.summary(id: id) {
                    openRoute(.note(path: summary.path, anchor: anchor), in: opening)
                }
            }
            return .handled
        case .missing(let target):
            openRoute(.missing(target: target), in: opening)
            return .handled
        case .tag(let name):
            openRoute(.tag(name: name), in: opening)
            return .handled
        case .asset(let id):
            Task {
                guard let asset = try? await session.assets.asset(id: id) else { return }
                if asset.kind == .base {
                    openRoute(.base(path: asset.path), in: opening)
                } else {
                    openAsset(asset)
                }
            }
            return .handled
        }
    }
}
