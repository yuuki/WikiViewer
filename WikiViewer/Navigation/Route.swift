//
//  Route.swift
//  WikiViewer
//

import SwiftUI
import WikiViewerKit

/// Navigation destinations. Notes and folders are addressed by vault path,
/// not database id, so a navigation stack survives a generation switch.
enum Route: Hashable {
    case folder(path: String)
    case note(path: String, anchor: Anchor?)
    case tag(name: String)
    case missing(target: String)
    case search
    case tags
}

struct Anchor: Hashable {
    var heading: String?
    var blockID: String?
}

@Observable
final class NavigationModel {
    var path: [Route] = []
    var quickSwitcherPresented = false

    func push(_ route: Route) {
        path.append(route)
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .folder(let path): FolderView(path: path)
        case .note(let path, let anchor): NoteView(path: path, anchor: anchor)
        case .tag(let name): TagNotesView(name: name)
        case .missing(let target): MissingNoteView(target: target)
        case .search: SearchView()
        case .tags: TagsView()
        }
    }
}

/// Handles taps on in-note links (wikilinks, tags, assets, external URLs).
struct LinkRouter {
    let session: LibrarySession
    let navigation: NavigationModel
    let currentNoteID: Int64?
    let scrollTo: (Anchor) -> Void

    func handle(_ url: URL) -> OpenURLAction.Result {
        guard let action = WikiLinkAction(url: url) else { return .discarded }
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
                    navigation.push(.note(path: summary.path, anchor: anchor))
                }
            }
            return .handled
        case .missing(let target):
            navigation.push(.missing(target: target))
            return .handled
        case .tag(let name):
            navigation.push(.tag(name: name))
            return .handled
        case .asset:
            return .handled
        }
    }
}

extension View {
    /// Toolbar button + sheet for the quick switcher.
    func quickSwitcherToolbar() -> some View {
        modifier(QuickSwitcherToolbar())
    }
}

struct QuickSwitcherToolbar: ViewModifier {
    @Environment(NavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        @Bindable var navigation = navigation
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigation.quickSwitcherPresented = true
                    } label: {
                        Label("Quick Switcher", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
            }
            .sheet(isPresented: $navigation.quickSwitcherPresented) {
                QuickSwitcherView { summary in
                    navigation.quickSwitcherPresented = false
                    navigation.push(.note(path: summary.path, anchor: nil))
                }
            }
    }
}
