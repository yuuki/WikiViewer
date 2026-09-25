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
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .files

    enum Tab: Hashable { case files, search, tags, settings }

    var body: some View {
        TabView(selection: $tab) {
            TabRoot(root: .folder(path: "")) 
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(Tab.files)
            TabRoot(root: .search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            TabRoot(root: .tags)
                .tabItem { Label("Tags", systemImage: "number") }
                .tag(Tab.tags)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, library.source != nil else { return }
            // Background freshness check at most every 15 minutes.
            if let last = library.lastCheck, Date().timeIntervalSince(last) < 15 * 60 { return }
            Task { await library.checkForUpdates() }
        }
    }
}

/// One tab: a NavigationStack whose routes are path-based, so they stay
/// valid across generation switches.
struct TabRoot: View {
    let root: Route
    @State private var navigation = NavigationModel()
    @Environment(Library.self) private var library

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
    }
}

#Preview {
    ContentView()
}
