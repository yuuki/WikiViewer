//
//  IndexerDaemon.swift
//  IndexerCore
//
//  Long-running scheduler around `Indexer`:
//   - FSEvents paths are debounced, then processed in bounded batches;
//   - files that changed while being read are retried with backoff;
//   - a periodic metadata reconciliation catches anything the watcher missed;
//   - publication waits for a quiet period, bounded by a maximum delay.
//

import Foundation
import WikiShared

public final class IndexerDaemon: Sendable {
    public let indexer: Indexer
    public let configuration: IndexerConfiguration

    public init(configuration: IndexerConfiguration) throws {
        self.configuration = configuration
        indexer = try Indexer(configuration: configuration)
    }

    enum Event: Sendable {
        case watch(WatchEvent)
        case tick
    }

    /// Runs until the task is cancelled. `onPublish` is a test hook.
    public func run(tick: Duration = .milliseconds(250), onPublish: (@Sendable (PublishResult) -> Void)? = nil) async throws {
        let config = configuration
        Log.info("initial reconciliation of \(config.vault.path)")
        let initial = try await indexer.reconcile()
        Log.info("initial reconciliation: \(initial)")
        let needsInitialPublication = initial.index.changed || indexer.publisher.currentManifest() == nil

        let (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let watcher = FSEventsWatcher(root: config.vault)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in watcher.events() {
                    continuation.yield(.watch(event))
                }
                // The watcher is only a fast path: if it could not start or
                // stopped, keep running on periodic reconciliation.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: tick)
                    continuation.yield(.tick)
                }
            }
            group.addTask { [indexer] in
                var scheduler = PublicationScheduler(configuration: config, now: .now)
                let dirty = await indexer.hasUnpublishedChanges
                if needsInitialPublication || dirty {
                    scheduler.recordChange(at: .now)
                }
                for await event in events {
                    try Task.checkCancellation()
                    let now = ContinuousClock.now
                    switch event {
                    case .watch(.paths(let paths)):
                        scheduler.recordEvent(paths: paths, at: now)
                    case .watch(.rescan(let subpath)):
                        scheduler.requestRescan(subpath, at: now)
                    case .tick:
                        try await Self.handleTick(indexer: indexer, scheduler: &scheduler, now: now, onPublish: onPublish)
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    static func handleTick(indexer: Indexer, scheduler: inout PublicationScheduler, now: ContinuousClock.Instant, onPublish: (@Sendable (PublishResult) -> Void)?) async throws {
        let due = scheduler.duePaths(at: now)
        if !due.isEmpty {
            let stats = try await indexer.process(paths: due)
            Log.info("fast path: \(stats)")
            scheduler.completed(due, unstable: stats.unstable, changed: stats.changed, at: ContinuousClock.now)
        }
        if let scope = scheduler.dueReconciliation(at: now) {
            do {
                let stats = try await indexer.reconcile(subpath: scope.subpath)
                Log.info("reconcile(\(scope.subpath ?? "/")): \(stats)")
                scheduler.reconciled(changed: stats.index.changed, unstable: stats.index.unstable, full: scope.subpath == nil, at: ContinuousClock.now)
            } catch {
                // e.g. subtree vanished between event and walk; fall back to full reconcile later.
                Log.warning("reconcile failed: \(error)")
                scheduler.reconciled(changed: false, unstable: [], full: false, at: ContinuousClock.now)
                scheduler.requestRescan(nil, at: ContinuousClock.now)
            }
        }
        if scheduler.shouldPublish(at: ContinuousClock.now, hasChanges: await indexer.hasUnpublishedChanges) {
            do {
                if let result = try await indexer.publish() {
                    Log.info("published generation \(result.manifest.generation) (\(result.manifest.noteCount) notes, \(result.manifest.database.byteSize) bytes) in \(String(format: "%.2f", result.seconds))s")
                    onPublish?(result)
                }
                scheduler.published()
            } catch {
                // The previous generation stays current. Try again after another quiet period.
                Log.error("publication failed: \(error)")
                scheduler.publicationFailed(at: ContinuousClock.now)
            }
        }
    }
}

/// Pure scheduling state, separated from I/O so it can be unit tested.
public struct PublicationScheduler: Sendable {
    let configuration: IndexerConfiguration
    /// Paths waiting to be processed and the earliest time they may be.
    var pending: [String: ContinuousClock.Instant] = [:]
    var attempts: [String: Int] = [:]
    var lastEventAt: ContinuousClock.Instant?
    var firstUnpublishedChangeAt: ContinuousClock.Instant?
    var lastChangeAt: ContinuousClock.Instant?
    var lastReconcileAt: ContinuousClock.Instant
    var rescanScopes: Set<String> = []
    var fullRescan = false
    var nextPublishAttempt: ContinuousClock.Instant?

    static let maxAttempts = 30

    public init(configuration: IndexerConfiguration, now: ContinuousClock.Instant) {
        self.configuration = configuration
        lastReconcileAt = now
    }

    public mutating func recordEvent(paths: [String], at now: ContinuousClock.Instant) {
        lastEventAt = now
        for path in paths where pending[path] == nil {
            pending[path] = now
        }
    }

    public mutating func requestRescan(_ subpath: String?, at now: ContinuousClock.Instant) {
        lastEventAt = now
        if let subpath { rescanScopes.insert(subpath) } else { fullRescan = true }
    }

    public mutating func recordChange(at now: ContinuousClock.Instant) {
        lastChangeAt = now
        if firstUnpublishedChangeAt == nil { firstUnpublishedChangeAt = now }
    }

    /// Paths ready for processing: the burst has been quiet for `debounce`
    /// and each path's retry time has passed.
    public func duePaths(at now: ContinuousClock.Instant) -> [String] {
        guard let last = lastEventAt, now - last >= configuration.debounce else {
            // Retries are still due even during a burst of unrelated events.
            return pending.filter { attempts[$0.key] != nil && $0.value <= now }.map(\.key).sorted()
        }
        return pending.filter { $0.value <= now }.map(\.key).sorted()
    }

    public mutating func completed(_ paths: [String], unstable: [String], changed: Bool, at now: ContinuousClock.Instant) {
        let unstableSet = Set(unstable)
        for path in paths where !unstableSet.contains(path) {
            pending[path] = nil
            attempts[path] = nil
        }
        for path in unstable {
            let n = (attempts[path] ?? 0) + 1
            if n > Self.maxAttempts {
                // Give up; periodic reconciliation will pick it up once stable.
                pending[path] = nil
                attempts[path] = nil
                Log.warning("\(path) kept changing during reads; deferring to reconciliation")
                continue
            }
            attempts[path] = n
            let backoff = configuration.unstableRetryDelay * min(n, 30)
            pending[path] = now + backoff
        }
        if changed { recordChange(at: now) }
    }

    public func dueReconciliation(at now: ContinuousClock.Instant) -> (subpath: String?, Void)? {
        if fullRescan || now - lastReconcileAt >= configuration.reconciliationInterval { return (nil, ()) }
        if let scope = rescanScopes.first { return (scope, ()) }
        return nil
    }

    public mutating func reconciled(changed: Bool, unstable: [String], full: Bool, at now: ContinuousClock.Instant) {
        if full {
            fullRescan = false
            rescanScopes.removeAll()
            lastReconcileAt = now
        } else if let first = rescanScopes.first {
            rescanScopes.remove(first)
        }
        for path in unstable {
            pending[path] = now + configuration.unstableRetryDelay
            attempts[path, default: 0] += 1
        }
        if changed { recordChange(at: now) }
    }

    /// Publish once the vault has been quiet for `quietPeriod`, or when the
    /// oldest unpublished change is older than `maximumPublicationDelay`.
    public func shouldPublish(at now: ContinuousClock.Instant, hasChanges: Bool) -> Bool {
        guard hasChanges, let first = firstUnpublishedChangeAt else { return false }
        if let next = nextPublishAttempt, now < next { return false }
        if now - first >= configuration.maximumPublicationDelay { return true }
        let lastActivity = [lastEventAt, lastChangeAt].compactMap { $0 }.max() ?? first
        return now - lastActivity >= configuration.quietPeriod && pending.isEmpty
    }

    public mutating func published() {
        firstUnpublishedChangeAt = nil
        nextPublishAttempt = nil
    }

    public mutating func publicationFailed(at now: ContinuousClock.Instant) {
        nextPublishAttempt = now + configuration.quietPeriod
    }
}
