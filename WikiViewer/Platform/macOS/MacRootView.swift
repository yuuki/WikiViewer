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
    @Environment(\.controlActiveState) private var activeState
    /// One stack of lists per section, so each section keeps its place.
    @State private var lists = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, NavigationModel()) })
    @State private var documents = NavigationModel(maxDepth: 100)
    @State private var selection = ListSelection()
    /// The document a list selection opened, while it is on top: browsing
    /// a list replaces it instead of adding a step to the history.
    @State private var selectedDocument: Route?
    @State private var restored = false
    /// Whether the inspector showed before reading mode, to restore after.
    @State private var inspectorBeforeReading: Bool?
    @SceneStorage("WikiViewer.mac.lists") private var savedLists: Data?
    @SceneStorage("WikiViewer.mac.documents") private var savedDocuments: Data?
    @SceneStorage("WikiViewer.mac.inspector") private var savedInspector = true
    @SceneStorage("WikiViewer.mac.joinedTabs") private var joinedTabs = false
    @AppStorage(NoteTextScale.defaultsKey) private var noteTextScale = 1.0

    var body: some View {
        let list = lists[app.tab] ?? NavigationModel()
        Group {
            // Reading mode: the document alone. (A three-column split view
            // on macOS cannot hide its content column.) The lists keep
            // their stacks meanwhile.
            if app.readingMode {
                documentColumn
            } else {
                NavigationSplitView {
                    MacSidebar()
                        .environment(\.openRoute, OpenRouteAction(handler: openFromDocument))
                        .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 280)
                } content: {
                    ListColumn(tab: app.tab, navigation: list, openRoute: OpenRouteAction(handler: openFromList), selection: selection)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
                } detail: {
                    // The note is what the window is for: the other columns
                    // give way before it gets too narrow to read.
                    documentColumn
                        .navigationSplitViewColumnWidth(min: 380, ideal: 680)
                }
            }
        }
        .overlay(alignment: .top) {
            if app.showingQuickOpen {
                ZStack(alignment: .top) {
                    // A click outside the palette closes it: the lists and
                    // the sidebar do not take the keyboard from its field.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { app.showingQuickOpen = false }
                    QuickOpenPanel { route, target in
                        target == .automatic ? show(route) : openElsewhere(route, target)
                    } onClose: {
                        app.showingQuickOpen = false
                    }
                    .padding(.top, 80)
                }
            }
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
        // Handoff from the iPhone: continue the note it was showing.
        .onContinueUserActivity(NoteActivity.type) { activity in
            if let route = NoteActivity.route(of: activity) { show(route) }
        }
        .onChange(of: lists.mapValues(\.path)) { save() }
        .onChange(of: documents.path) {
            save()
            // The selection follows the document, so its row can be
            // clicked again after a link inside it moved on.
            if let top = documents.path.last, selection.selected != top { selection.selected = top }
        }
        .onChange(of: app.showsInspector) { savedInspector = app.showsInspector }
        .onChange(of: app.readingMode) {
            if app.readingMode {
                inspectorBeforeReading = app.showsInspector
                app.showsInspector = false
            } else if let inspectorBeforeReading {
                app.showsInspector = inspectorBeforeReading
                self.inspectorBeforeReading = nil
            }
        }
        // The Dock menu opens notes in the window last in front.
        .onChange(of: activeState, initial: true) {
            guard activeState == .key else { return }
            DockMenu.openInWindow = { show($0) }
            DockMenu.openWindow = openWindow
        }
        // The Graph section lists clusters; its map belongs in the detail column.
        .onChange(of: app.tab) {
            // Back to the section the window was left on: the documents
            // are restored as they were, not topped with the map.
            let restoring = app.restoringTab
            app.restoringTab = false
            guard app.tab == .graph, documents.path.last != .graph,
                  !restoring || documents.path.isEmpty else { return }
            openDocument(.graph)
        }
    }

    private var documentColumn: some View {
        DocumentColumn(navigation: documents)
            .environment(\.noteTextScale, noteTextScale * NoteTextScale.readingSize)
            .environment(documents)
            .environment(\.openRoute, OpenRouteAction(handler: openFromDocument))
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
        switch RouteDispatch.dispatch(route, from: .list) {
        case .pushList(let route): lists[app.tab]?.push(route)
        case .showList(let tab, let routes):
            app.tab = tab
            lists[tab]?.reset(to: routes)
        case .openDocument(let route): openDocument(route)
        }
    }

    /// A row of a content-column list was selected (ListSelection).
    private func select(_ route: Route, _ input: ListSelection.Input) {
        if input == .click {
            let target = RouteTarget.fromCurrentEvent
            // A new tab or window; the selection stays where it was.
            guard target == .automatic else { return openElsewhere(route, target) }
        }
        if route.isList {
            // A folder or tag replaces the list: not while arrowing through.
            guard input != .arrow else {
                selection.selected = route
                return
            }
            selection.selected = nil
            selection.focusesNextList = input == .activate
            lists[app.tab]?.push(route)
        } else {
            selection.selected = route
            openDocument(route, fromSelection: true)
        }
    }

    private func openDocument(_ route: Route, fromSelection: Bool = false) {
        if fromSelection, let selectedDocument, documents.path.last == selectedDocument {
            documents.replaceTop(with: route)
        } else {
            documents.push(route)
        }
        selectedDocument = fromSelection ? route : nil
    }

    /// From a document or the sidebar: documents stack up in detail; a list
    /// is shown in its own section of the content column.
    private func openFromDocument(_ route: Route, _ target: RouteTarget) {
        let target = target == .automatic ? RouteTarget.fromCurrentEvent : target
        guard target == .automatic else { return openElsewhere(route, target) }
        show(route)
    }

    private func show(_ route: Route) {
        switch RouteDispatch.dispatch(route, from: .document) {
        case .pushList(let route):
            lists[app.tab]?.push(route)
        case .showList(let tab, let routes):
            app.tab = tab
            lists[tab]?.reset(to: routes)
        case .openDocument(let route):
            openDocument(route)
        }
    }

    private func openElsewhere(_ route: Route, _ target: RouteTarget) {
        let request = WindowRequest(route: route)
        openWindow(value: target == .newTab ? MacWindowTabs.asTab(request) : request)
    }

    // MARK: State

    private func restore() {
        app.documentNavigation = documents
        app.openHandler = { show($0) }
        selection.handler = select
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

    @Environment(Library.self) private var library
    @State private var today: NoteSummary?

    var body: some View {
        List(selection: Binding(get: { app.tab }, set: { if let tab = $0 { app.tab = tab } })) {
            Section {
                Label("Files", systemImage: "folder").tag(AppTab.files)
                Label("Tags", systemImage: "number").tag(AppTab.tags)
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(AppTab.graph)
                Label("Search", systemImage: "magnifyingglass").tag(AppTab.search)
            }
            // The recent notes head the Files list (and Go > Recent Notes);
            // today's note and the pins are here only, beside every section.
            if let today {
                Section {
                    shortcut("Today", systemImage: "calendar", route: .note(path: today.path, anchor: nil))
                        .notePreviewMenu(path: today.path, title: today.title)
                }
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
        .safeAreaInset(edge: .bottom) { UpdateStatusFooter() }
        // Again on a new day, when the app has been open overnight.
        .task(id: TodayKey(session: library.session?.id, day: LibraryHomeSections.dayString(.now))) {
            guard let session = library.session else { return }
            today = await LibraryHomeSections.findTodaysNote(in: session)
        }
    }

    private struct TodayKey: Equatable {
        var session: String?
        var day: String
    }

    /// A row that opens `route` rather than selecting a section.
    private func shortcut(_ title: LocalizedStringKey, systemImage: String, route: Route) -> some View {
        Button {
            openRoute(route)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// At the foot of the sidebar, whatever the section: an update under way,
/// or the last one failed (the Files list says so only at its top).
private struct UpdateStatusFooter: View {
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app

    var body: some View {
        switch library.updateStatus {
        case .checking:
            row { ProgressView().controlSize(.small) } text: { Text("Checking for updates…") }
        case .downloading(let bytes):
            row { ProgressView().controlSize(.small) } text: {
                Text("Updating… \(bytes.formatted(.byteCount(style: .file)))")
            }
        case .failed(let message):
            Button {
                app.showSettings()
            } label: {
                row {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                } text: {
                    Text("Couldn't Update")
                }
            }
            .buttonStyle(.plain)
            .help(Text("Showing the last downloaded snapshot. \(message)"))
        case .idle, .upToDate, .updated:
            EmptyView()
        }
    }

    private func row(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> Text) -> some View {
        HStack(spacing: 8) {
            icon()
            text().lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}

/// The document on top of the window's history, with back and forward.
/// Not a NavigationStack: its back button would land in the content
/// column's toolbar, next to the list's title, and it has no forward.
private struct DocumentColumn: View {
    let navigation: NavigationModel
    @Environment(AppModel.self) private var app

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
            ToolbarItem(placement: .navigation) {
                Button("Open Quickly", systemImage: "magnifyingglass") { app.showingQuickOpen = true }
                    .help("Open a note by its title (⌘O)")
            }
        }
    }

    struct DocumentID: Hashable {
        var depth: Int
        var route: Route
    }
}

/// The section's lists in a NavigationStack, so the lists left behind keep
/// their place. Going back is a bar above the list (or ←): the stack's own
/// back button, like the toolbar's back and forward buttons next to the
/// window title, would read as the documents' history.
private struct ListColumn: View {
    let tab: AppTab
    let navigation: NavigationModel
    let openRoute: OpenRouteAction
    let selection: ListSelection

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            LibraryReady { root }
                .listColumnEnvironment(navigation: navigation, openRoute: openRoute, selection: selection)
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                        .navigationBarBackButtonHidden()
                        .safeAreaInset(edge: .top, spacing: 0) {
                            BackBar(title: parentTitle(of: route)) {
                                selection.focusesNextList = true
                                navigation.back()
                            }
                        }
                        // Pushed screens do not inherit environment set
                        // around the NavigationStack on macOS.
                        .listColumnEnvironment(navigation: navigation, openRoute: openRoute, selection: selection)
                }
        }
        .listColumnEnvironment(navigation: navigation, openRoute: openRoute, selection: selection)
        // Each section has its own stack.
        .id(tab)
    }

    /// The list going back from `route` returns to.
    private func parentTitle(of route: Route) -> String {
        let index = navigation.path.lastIndex(of: route) ?? 0
        switch index > 0 ? navigation.path[index - 1] : nil {
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
}

private struct BackBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: "chevron.backward")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .help("Back (←)")
            Divider()
        }
        .background(.bar)
    }
}

private extension View {
    func listColumnEnvironment(navigation: NavigationModel, openRoute: OpenRouteAction, selection: ListSelection) -> some View {
        environment(navigation)
            .environment(\.openRoute, openRoute)
            .environment(\.listSelection, selection)
    }
}
#endif
