//
//  MacRootView.swift
//  WikiViewer
//
//  A macOS window: the sections and pinned notes in the sidebar, the
//  section's lists in the content column, and documents in the detail
//  column. Lists (folders, tags, search results) open in the content column
//  and documents (notes, bases, graphs) in the detail column, wherever the
//  link was; the detail column keeps browser-like history (⌘[ and ⌘]).
//  ⌘-click opens a new tab, ⌥⌘-click a new window.
//

#if os(macOS)
import SwiftUI
import WikiShared
import WikiViewerKit

struct MacRootView: View {
    let request: WindowRequest?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// One stack of lists per section, so each section keeps its place.
    @State private var lists = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, NavigationModel()) })
    @State private var documents = NavigationModel()
    @State private var restored = false
    @SceneStorage("WikiViewer.mac.lists") private var savedLists: Data?
    @SceneStorage("WikiViewer.mac.documents") private var savedDocuments: Data?
    @SceneStorage("WikiViewer.mac.inspector") private var savedInspector = true
    @SceneStorage("WikiViewer.mac.joinedTabs") private var joinedTabs = false

    var body: some View {
        let list = lists[app.tab] ?? NavigationModel()
        NavigationSplitView {
            MacSidebar()
                .environment(\.openRoute, OpenRouteAction(handler: openFromDocument))
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 280)
        } content: {
            ListColumn(tab: app.tab, navigation: list)
                .environment(list)
                .environment(\.openRoute, OpenRouteAction(handler: openFromList))
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 480)
        } detail: {
            DocumentColumn(navigation: documents)
                .environment(documents)
                .environment(\.openRoute, OpenRouteAction(handler: openFromDocument))
        }
        .background { TabTitle(title: documentTitle) }
        .background {
            // Only when first opened: a restored window keeps the tab
            // group the system restores.
            if let parent = request?.tabbedWith, !joinedTabs {
                TabJoiner(parent: parent) { joinedTabs = true }
            }
        }
        .onAppear(perform: restore)
        .onChange(of: lists.mapValues(\.path)) { save() }
        .onChange(of: documents.path) { save() }
        .onChange(of: app.showsInspector) { savedInspector = app.showsInspector }
        // The Graph section lists clusters; its map belongs in the detail column.
        .onChange(of: app.tab) {
            if app.tab == .graph, documents.path.last != .graph { documents.push(.graph) }
        }
    }

    /// What the detail column shows, for the window's tab.
    private var documentTitle: String? {
        guard let route = documents.path.last else { return nil }
        switch route {
        case .note(let path, _):
            if let note = documents.note, note.detail.path == path { return note.detail.title }
            return VaultPath.basename(of: path)
        case .base(let path), .localGraph(let path): return VaultPath.basename(of: path)
        case .missing(let target): return target
        case .graph, .graphCluster: return String(localized: "Graph")
        case .folder, .tag, .tags, .search, .recents: return nil
        }
    }

    // MARK: Opening routes

    /// From the content column: lists replace it, documents open in detail.
    private func openFromList(_ route: Route, _ target: RouteTarget) {
        let target = target == .automatic ? RouteTarget.fromCurrentEvent : target
        guard target == .automatic else { return openElsewhere(route, target) }
        if route.isList {
            lists[app.tab]?.push(route)
        } else {
            documents.push(route)
        }
    }

    /// From a document or the sidebar: documents stack up in detail; a list
    /// is shown in its own section of the content column.
    private func openFromDocument(_ route: Route, _ target: RouteTarget) {
        let target = target == .automatic ? RouteTarget.fromCurrentEvent : target
        guard target == .automatic else { return openElsewhere(route, target) }
        show(route)
    }

    private func show(_ route: Route) {
        switch route {
        case .folder(let path):
            showList(in: .files, Self.folderChain(path))
        case .recents:
            showList(in: .files, [.recents])
        case .tag(let name):
            showList(in: .tags, [.tag(name: name)])
        case .tags:
            showList(in: .tags, [])
        case .search:
            app.tab = .search
        case .note, .base, .missing, .graph, .graphCluster, .localGraph:
            documents.push(route)
        }
    }

    private func showList(in tab: AppTab, _ routes: [Route]) {
        app.tab = tab
        lists[tab]?.reset(to: routes)
    }

    /// A folder with its parents, so going back walks up the tree.
    static func folderChain(_ path: String) -> [Route] {
        let components = path.split(separator: "/").map(String.init)
        return components.indices.map { .folder(path: components[...$0].joined(separator: "/")) }
    }

    private func openElsewhere(_ route: Route, _ target: RouteTarget) {
        let request = WindowRequest(route: route)
        openWindow(value: target == .newTab ? MacWindowTabs.asTab(request) : request)
    }

    // MARK: State

    private func restore() {
        app.documentNavigation = documents
        guard !restored else { return }
        restored = true
        app.showsInspector = savedInspector
        let decoder = JSONDecoder()
        if let savedLists, let saved = try? decoder.decode([String: [Route]].self, from: savedLists) {
            for (key, path) in saved {
                if let tab = AppTab(rawValue: key) { lists[tab]?.reset(to: path) }
            }
        }
        if let savedDocuments, let path = try? decoder.decode([Route].self, from: savedDocuments) {
            documents.reset(to: path)
        } else if let route = request?.route {
            // A new window or tab: show what it was opened for.
            show(route)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        let paths = Dictionary(uniqueKeysWithValues: lists.map { ($0.key.rawValue, $0.value.path) })
        savedLists = try? encoder.encode(paths)
        savedDocuments = try? encoder.encode(documents.path)
    }
}

/// The sections, and the pinned notes for one click access.
private struct MacSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(ReadingHistory.self) private var history
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        List(selection: Binding(get: { app.tab }, set: { if let tab = $0 { app.tab = tab } })) {
            Section {
                Label("Files", systemImage: "folder").tag(AppTab.files)
                Label("Tags", systemImage: "number").tag(AppTab.tags)
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(AppTab.graph)
                Label("Search", systemImage: "magnifyingglass").tag(AppTab.search)
            }
            if !history.pins.isEmpty {
                Section("Pinned") {
                    ForEach(history.pins) { entry in
                        Button {
                            openRoute(.note(path: entry.path, anchor: nil))
                        } label: {
                            Label(entry.title, systemImage: "pin")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .notePreviewMenu(path: entry.path, title: entry.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The document on top of the window's history, with back and forward.
/// Not a NavigationStack: its back button would land in the content
/// column's toolbar, next to the list's title, and it has no forward.
private struct DocumentColumn: View {
    let navigation: NavigationModel

    var body: some View {
        LibraryReady {
            if let route = navigation.path.last {
                RouteView(route: route)
                    // Each entry starts afresh; a note returns to where it
                    // was read (ReadingHistory).
                    .id(DocumentID(depth: navigation.path.count, route: route))
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "doc.text",
                                       description: Text("Choose a note in the list, or search with ⌘O."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { navigation.back() }
                    .disabled(!navigation.canGoBack)
                    .help("Go back (⌘[)")
                Button("Forward", systemImage: "chevron.forward") { navigation.forward() }
                    .disabled(!navigation.canGoForward)
                    .help("Go forward (⌘])")
            }
        }
    }

    struct DocumentID: Hashable {
        var depth: Int
        var route: Route
    }
}

/// The section's list, or the list opened from it, with a way back. The
/// way back is a bar above the list: the toolbar's back and forward
/// buttons, next to the window title, are the documents' history.
private struct ListColumn: View {
    let tab: AppTab
    let navigation: NavigationModel

    var body: some View {
        LibraryReady {
            let route = navigation.path.last
            Group {
                if let route {
                    RouteView(route: route)
                } else {
                    root
                }
            }
            // A new list starts from its own state (FolderView keeps its
            // model per instance).
            .id(ListID(tab: tab, route: route))
            .safeAreaInset(edge: .top, spacing: 0) {
                if navigation.canGoBack {
                    VStack(spacing: 0) {
                        Button {
                            navigation.back()
                        } label: {
                            Label(parentTitle, systemImage: "chevron.backward")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider()
                    }
                    .background(.bar)
                }
            }
        }
    }

    /// The list going back returns to.
    private var parentTitle: String {
        let parent = navigation.path.dropLast().last
        switch parent {
        case .folder(let path): return VaultPath.fileName(of: path)
        case .tag(let name): return "#" + name
        case .recents: return String(localized: "Recent")
        default:
            switch tab {
            case .files: return String(localized: "Vault")
            case .tags: return String(localized: "Tags")
            case .search: return String(localized: "Search")
            case .graph: return String(localized: "Clusters")
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .files: FolderView(path: "")
        case .tags: TagsView()
        case .search: SearchView()
        case .graph: ClusterListView().navigationTitle("Clusters")
        }
    }

    struct ListID: Hashable {
        var tab: AppTab
        var route: Route?
    }
}
#endif
