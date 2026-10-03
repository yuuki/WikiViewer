//
//  UpdateCoordinator.swift
//  WikiViewer
//
//  Keeps the library current on macOS. iOS follows the source while a
//  window is in the foreground (ContentView) and refreshes in the
//  background; a Mac app keeps running behind other windows, so here one
//  watcher runs for the whole process: restarted when the source changes,
//  paused while the Mac sleeps, and checking again at once on wake and when
//  the app comes to the front (a polled folder may be minutes from its next
//  look, and a failed update waiting out its backoff).
//

#if os(macOS)
import AppKit
import WikiViewerKit

@MainActor
final class UpdateCoordinator {
    private let library: Library
    private var task: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init(library: Library) {
        self.library = library
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopWatching() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkOnActivation() }
            },
        ]
        observeSource()
        restart()
    }

    /// Restarts the watcher whenever the configured source changes.
    private func observeSource() {
        withObservationTracking {
            _ = library.source
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.restart()
                self?.observeSource()
            }
        }
    }

    private func restart() {
        stopWatching()
        guard library.source != nil else { return }
        let library = library
        task = Task { await library.watchForUpdates() }
    }

    /// Not while an update is under way, nor more than once a minute when
    /// switching between apps.
    private func checkOnActivation() {
        switch library.updateStatus {
        case .checking, .downloading: return
        default: break
        }
        if let lastCheck = library.lastCheck, Date.now.timeIntervalSince(lastCheck) < Self.activationInterval { return }
        restart()
    }

    static let activationInterval: TimeInterval = 60

    private func stopWatching() {
        task?.cancel()
        task = nil
    }
}
#endif
