//
//  WikiViewerApp.swift
//  WikiViewer
//
//  Created by Yuuki Tsubouchi on 2026/09/24.
//

import SwiftUI
import WikiViewerKit
#if os(iOS)
import BackgroundTasks
#endif

@main
struct WikiViewerApp: App {
    @State private var library: Library?
    @State private var startupError: String?
    @State private var app = AppModel()
    @State private var history = ReadingHistory()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    ContentView()
                        .environment(library)
                        .environment(app)
                        .environment(history)
                        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                            library.imageCache.removeAll()
                        }
                } else if let startupError {
                    ContentUnavailableView("Can't Start", systemImage: "exclamationmark.triangle", description: Text(startupError))
                } else {
                    ProgressView()
                }
            }
            .task {
                guard library == nil else { return }
                do {
                    let library = try SharedLibrary.library()
                    self.library = library
                    await library.bootstrap()
                } catch {
                    startupError = error.localizedDescription
                }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search Notes") { app.showSearch() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Find in Vault") { app.showSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
        // Lets iOS fetch a new snapshot while the app is not in use, so it is
        // already current when opened. Small deltas fit the time iOS allows.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
        #endif
    }
}

/// The one Library of the process, created on first use — by the window, or
/// by a background refresh when iOS launches the app without one.
@MainActor
enum SharedLibrary {
    private static var instance: Library?

    static func library() throws -> Library {
        if let instance { return instance }
        let library = Library(store: try GenerationStore(root: try GenerationStore.defaultRoot()))
        instance = library
        return library
    }
}

#if os(iOS)
enum BackgroundRefresh {
    /// Must be listed in BGTaskSchedulerPermittedIdentifiers (Info.plist).
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "WikiViewer") + ".refresh" }

    /// Asks iOS for a refresh opportunity; iOS decides when (not before 15 minutes).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        guard let library = try? await SharedLibrary.library(), await library.source != nil else { return }
        // Expiration cancels this task; the updater then leaves the current
        // generation untouched.
        await library.checkForUpdates()
    }
}
#endif
