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

/// One stack of screens with browser-like history (NavigationHistory),
/// observable by the views that show it.
@Observable
final class NavigationModel {
    private(set) var history: NavigationHistory<Route>
    /// The note on top of this stack, set by NoteView while it is showing.
    var note: NoteFocus?

    /// `maxDepth` bounds a stack that grows with every note opened (the
    /// macOS detail column).
    init(maxDepth: Int = .max) {
        history = NavigationHistory(maxDepth: maxDepth)
    }

    /// Settable for NavigationStack: a shorter prefix is going back.
    var path: [Route] {
        get { history.path }
        set { history.setPath(newValue) }
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func push(_ route: Route) { history.push(route) }
    func replaceTop(with route: Route) { history.replaceTop(with: route) }
    func back() { history.back() }
    func forward() { history.forward() }

    /// Replaces the whole stack, e.g. to show a folder with its parents.
    func reset(to routes: [Route]) { history.setPath(routes) }
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
    let scrollTo: (NoteAnchor) -> Void
    /// Presents an attachment; bases are pushed as a screen instead.
    let openAsset: (AssetInfo) -> Void

    func handle(_ url: URL) -> OpenURLAction.Result {
        guard let action = WikiLinkAction(url: url) else { return .discarded }
        let opening = RouteTarget.fromCurrentEvent
        switch action {
        case .external:
            return .systemAction
        case .note(let id, let heading, let blockID):
            let anchor = (heading != nil || blockID != nil) ? NoteAnchor(heading: heading, blockID: blockID) : nil
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
