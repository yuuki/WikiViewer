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
    @State private var startup = LibraryStartup()
    @State private var history = ReadingHistory()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryGate(startup: startup) {
                // Each window has its own tab and navigation; the library
                // and the reading history are shared by all of them.
                WindowRoot()
            }
            .environment(history)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
        .commands {
            AppCommands(startup: startup, history: history)
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

        #if os(macOS)
        Settings {
            LibraryGate(startup: startup) {
                NavigationStack { SettingsView() }
                    .formStyle(.grouped)
            }
            .environment(history)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 560)
        }
        #endif
    }
}

/// Opens the shared library once, for whichever scene asks first.
@MainActor
@Observable
final class LibraryStartup {
    private(set) var library: Library?
    private(set) var error: String?

    func start() async {
        guard library == nil, error == nil else { return }
        do {
            let library = try SharedLibrary.library()
            self.library = library
            await library.bootstrap()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shows `content` with the library in its environment once it is open.
struct LibraryGate<Content: View>: View {
    let startup: LibraryStartup
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let library = startup.library {
                content().environment(library)
            } else if let error = startup.error {
                ContentUnavailableView("Can't Start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task { await startup.start() }
    }
}

/// One window's UI state.
struct WindowRoot: View {
    @State private var app = AppModel()

    var body: some View {
        ContentView()
            .environment(app)
            .focusedSceneValue(\.appModel, app)
    }
}

/// The one Library of the process, created on first use — by a window, or
/// by a background refresh when iOS launches the app without one.
@MainActor
enum SharedLibrary {
    private static var instance: Library?
    private static var memoryPressure: MemoryPressureMonitor?
    #if os(macOS)
    private static var updates: UpdateCoordinator?
    #endif

    static func library() throws -> Library {
        if let instance { return instance }
        let library = Library(store: try GenerationStore(root: try GenerationStore.defaultRoot()))
        instance = library
        memoryPressure = MemoryPressureMonitor { library.imageCache.removeAll() }
        #if os(macOS)
        // A Mac app keeps running behind other windows, so it follows the
        // source for as long as it runs, not per window.
        let updates = UpdateCoordinator(library: library)
        updates.start()
        self.updates = updates
        #endif
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
