//
//  ContentView.swift
//  WikiViewer
//
//  Created by Yuuki Tsubouchi on 2026/09/24.
//

import SwiftUI
import WikiViewerKit

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(ReadingHistory.self) private var history
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("WikiViewer.tab") private var savedTab: AppTab = .files

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Files", systemImage: "folder", value: AppTab.files) {
                TabRoot(root: .folder(path: ""), storageKey: "WikiViewer.path.files")
            }
            Tab("Tags", systemImage: "number", value: AppTab.tags) {
                TabRoot(root: .tags, storageKey: "WikiViewer.path.tags")
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
            // The system search tab: its field takes titles and full text,
            // replacing the separate quick switcher.
            Tab(value: AppTab.search, role: .search) {
                TabRoot(root: .search, storageKey: "WikiViewer.path.search")
            }
        }
        // Reopen the tab the reader left.
        .onAppear { app.tab = savedTab }
        .onChange(of: app.tab) { savedTab = app.tab }
        .onChange(of: scenePhase) {
            if scenePhase != .active { history.save() }
        }
        // While the app is in the foreground, keep the snapshot current:
        // check on activation, then follow the source (long poll or polling).
        // Leaving the foreground cancels the task.
        .task(id: WatchKey(active: scenePhase == .active, source: library.source)) {
            guard scenePhase == .active, library.source != nil else { return }
            await library.watchForUpdates()
        }
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
    let root: Route
    @State private var navigation = NavigationModel()
    @Environment(Library.self) private var library
    /// The tab's navigation stack, restored on the next launch.
    @SceneStorage private var savedPath: Data?

    init(root: Route, storageKey: String) {
        self.root = root
        _savedPath = SceneStorage(storageKey)
    }

    var body: some View {
        NavigationStack(path: $navigation.path) {
            Group {
                switch library.state {
                case .loading:
                    ProgressView("Opening library…")
                case .empty:
                    ContentUnavailableView("No Snapshot", systemImage: "tray", description: Text("Choose an update source in Settings."))
                case .failed(let message):
                    ContentUnavailableView("Couldn't Open Library", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    RouteView(route: root)
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .environment(navigation)
        .onAppear {
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

#Preview {
    ContentView()
        .environment(AppModel())
        .environment(ReadingHistory())
}
