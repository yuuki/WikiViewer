//
//  ContentView.swift
//  WikiViewer
//
//  Created by Yuuki Tsubouchi on 2026/09/24.
//

import SwiftUI
import WikiViewerKit

/// One window: tabs on iOS, a split view on macOS (MacRootView).
struct ContentView: View {
    /// What the window was opened to show (macOS: a new tab or window).
    var request: WindowRequest?
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(ReadingHistory.self) private var history
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @SceneStorage("WikiViewer.tab") private var savedTab: AppTab = .files

    var body: some View {
        @Bindable var app = app
        root
            #if os(macOS)
            // Settings is its own window (⌘,).
            .onChange(of: app.showingSettings) {
                guard app.showingSettings else { return }
                app.showingSettings = false
                openSettings()
            }
            #else
            .sheet(isPresented: $app.showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { app.showingSettings = false }
                            }
                        }
                }
            }
            #endif
            #if os(iOS)
            // Handoff from the Mac: continue the note it was showing.
            .onContinueUserActivity(NoteActivity.type) { activity in
                guard let route = NoteActivity.route(of: activity) else { return }
                app.tab = .files
                app.navigations[.files]?.push(route)
            }
            #endif
            // Reopen the tab the reader left.
            .onAppear { app.restoreTab(savedTab) }
            .onChange(of: app.tab) { savedTab = app.tab }
            .onChange(of: scenePhase) {
                if scenePhase != .active { history.save() }
            }
            #if os(iOS)
            // While the app is in the foreground, keep the snapshot current:
            // check on activation, then follow the source (long poll or polling).
            // Leaving the foreground cancels the task. (On macOS the
            // UpdateCoordinator follows the source for the whole app.)
            .task(id: WatchKey(active: scenePhase == .active, source: library.source)) {
                guard scenePhase == .active, library.source != nil else { return }
                await library.watchForUpdates()
            }
            #endif
    }

    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        MacRootView(request: request)
        #else
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Files", systemImage: "folder", value: AppTab.files) {
                TabRoot(tab: .files, root: .folder(path: ""), storageKey: "WikiViewer.path.files")
            }
            Tab("Tags", systemImage: "number", value: AppTab.tags) {
                TabRoot(tab: .tags, root: .tags, storageKey: "WikiViewer.path.tags")
            }
            Tab("Graph", systemImage: "point.3.connected.trianglepath.dotted", value: AppTab.graph) {
                TabRoot(tab: .graph, root: .graph, storageKey: "WikiViewer.path.graph")
            }
            // The system search tab: its field takes titles and full text,
            // replacing the separate quick switcher.
            Tab(value: AppTab.search, role: .search) {
                TabRoot(tab: .search, root: .search, storageKey: "WikiViewer.path.search")
            }
        }
        #endif
    }
}

/// Restarts the update watcher when the app becomes active or the source changes.
private struct WatchKey: Equatable {
    var active: Bool
    var source: SourceConfiguration?
}

/// One tab: a NavigationStack whose routes are path-based, so they stay
/// valid across generation switches.
struct TabRoot: View {
    let tab: AppTab
    let root: Route
    @State private var navigation = NavigationModel()
    @Environment(AppModel.self) private var app
    /// The tab's navigation stack, restored on the next launch.
    @SceneStorage private var savedPath: Data?

    init(tab: AppTab, root: Route, storageKey: String) {
        self.tab = tab
        self.root = root
        _savedPath = SceneStorage(storageKey)
    }

    var body: some View {
        let openRoute = OpenRouteAction { [navigation] route, _ in navigation.push(route) }
        NavigationStack(path: $navigation.path) {
            LibraryReady {
                RouteView(route: root)
            }
            .navigationDestination(for: Route.self) {
                RouteView(route: $0)
                    .environment(navigation)
                    .environment(\.openRoute, openRoute)
            }
        }
        .environment(navigation)
        .environment(\.openRoute, openRoute)
        .onAppear {
            // The menu bar's commands act on the tab that is showing.
            app.navigations[tab] = navigation
            if navigation.path.isEmpty, let savedPath,
               let path = try? JSONDecoder().decode([Route].self, from: savedPath) {
                navigation.path = path
            }
        }
        .onChange(of: navigation.path) {
            savedPath = try? JSONEncoder().encode(navigation.path)
        }
    }
}

/// `content` once a snapshot is open; otherwise what to do about it.
struct LibraryReady<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app

    var body: some View {
        switch library.state {
        case .loading:
            ProgressView("Opening library…")
        case .empty:
            ContentUnavailableView {
                Label("No Snapshot", systemImage: "tray")
            } description: {
                Text("Connect the folder or URL where your Mac publishes your vault.")
            } actions: {
                Button("Connect Your Vault") { app.showSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Open Settings") { app.showSettings() }
            }
        case .ready:
            content()
        }
    }
}

/// What a new window or tab opens to. The id makes every request distinct,
/// so opening a note that another window was once opened to makes a new
/// window instead of bringing that one forward.
struct WindowRequest: Hashable, Codable {
    var route: Route?
    /// The window to join as a tab (macOS window number), if any.
    var tabbedWith: Int?
    var id = UUID()
}

#Preview {
    ContentView()
        .environment(AppModel())
        .environment(ReadingHistory())
}
