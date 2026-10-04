//
//  IndexerDaemon.swift
//  IndexerCore
//
//  Long-running scheduler around `Indexer`:
//   - FSEvents paths are debounced, then processed in bounded batches;
//   - files that changed while being read are retried with backoff;
//   - a periodic metadata reconciliation catches anything the watcher missed;
//   - publication waits for a quiet period — a few seconds after a small
//     edit, longer after a burst — bounded by a maximum delay; events for
//     paths that are never indexed (e.g. `.obsidian/`) do not count;
//   - edits to the exclude and include files change the folder filter
//     without a restart.
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
                var patternFiles = FilterFiles(configuration: config)
                var extrasCheckedAt = ContinuousClock.now
                let dirty = await indexer.hasUnpublishedChanges
                if needsInitialPublication || dirty {
                    scheduler.recordChange(at: .now)
                }
                for await event in events {
                    try Task.checkCancellation()
                    let now = ContinuousClock.now
                    switch event {
                    case .watch(.paths(let paths)):
                        // Obsidian rewrites `.obsidian/workspace.json` whenever
                        // a note is opened or scrolled; such events must not
                        // keep postponing publication.
                        let filter = await indexer.filter
                        let relevant = paths.filter { !Self.isIgnored($0, filter: filter) }
                        if !relevant.isEmpty {
                            scheduler.recordEvent(paths: relevant, at: now)
                        }
                    case .watch(.rescan(let subpath)):
                        if let subpath, Self.isIgnored(subpath, filter: await indexer.filter) { continue }
                        scheduler.requestRescan(subpath, at: now)
                    case .tick:
                        if !patternFiles.isEmpty {
                            await Self.checkFilterFiles(indexer: indexer, files: &patternFiles, scheduler: &scheduler, now: now)
                        }
                        if config.extrasDirectory != nil, now - extrasCheckedAt >= config.extrasCheckInterval {
                            extrasCheckedAt = now
                            if await indexer.checkExtras() {
                                Log.info("extras changed; publishing")
                                scheduler.recordChange(at: now)
                            }
                        }
                        try await Self.handleTick(indexer: indexer, scheduler: &scheduler, now: now, onPublish: onPublish)
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Paths the indexer never reads: hidden files and anything inside a
    /// hidden or excluded folder or outside the included folders (the same
    /// rule as VaultFiles). `path` may name a file or a folder.
    static func isIgnored(_ path: String, filter: VaultFilter) -> Bool {
        VaultPath.fileName(of: path).hasPrefix(".") || filter.excludesAncestor(of: path) || !filter.mayInclude(path)
    }

    /// Applies changed exclude / include files. An unreadable or invalid
    /// file (or an include file that lists no folder) keeps the current
    /// filter, so a half-saved edit never un-excludes a folder or publishes
    /// the whole vault.
    static func checkFilterFiles(indexer: Indexer, files: inout FilterFiles, scheduler: inout PublicationScheduler, now: ContinuousClock.Instant) async {
        guard files.poll(at: now), let exclude = files.excludePatterns, let include = files.includePatterns else { return }
        let paths = files.paths.joined(separator: ", ")
        do {
            let filter = try indexer.configuration.makeFilter(excludeFilePatterns: exclude, includeFilePatterns: include)
            guard await indexer.updateFilter(filter) else { return }
            let excluded = filter.patterns.isEmpty ? "nothing" : filter.patterns.joined(separator: ", ")
            let included = filter.includePatterns.isEmpty ? "the whole vault" : filter.includePatterns.joined(separator: ", ")
            Log.info("\(paths) changed; now publishing \(included), excluding \(excluded); reconciling the vault")
            scheduler.requestRescan(nil, at: now)
        } catch {
            Log.error("\(paths): \(error); keeping the current folder filter")
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
    /// Files processed with changes since the last publication, and whether
    /// a change of unknown size (reconciliation) is pending: together they
    /// decide between the quick and the full quiet period.
    var changedFilesSincePublication = 0
    var largeChangePending = false

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
        if changed {
            changedFilesSincePublication += paths.count - unstableSet.count
            recordChange(at: now)
        }
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
        if changed {
            largeChangePending = true
            recordChange(at: now)
        }
    }

    /// Publish once the vault has been quiet for the quiet period — the short
    /// `quickQuietPeriod` after a small edit, `quietPeriod` after a burst or
    /// a reconciliation — or when the oldest unpublished change is older than
    /// `maximumPublicationDelay`.
    public func shouldPublish(at now: ContinuousClock.Instant, hasChanges: Bool) -> Bool {
        guard hasChanges, let first = firstUnpublishedChangeAt else { return false }
        if let next = nextPublishAttempt, now < next { return false }
        if now - first >= configuration.maximumPublicationDelay { return true }
        let lastActivity = [lastEventAt, lastChangeAt].compactMap { $0 }.max() ?? first
        return now - lastActivity >= currentQuietPeriod && pending.isEmpty
    }

    var currentQuietPeriod: Duration {
        let small = !largeChangePending && changedFilesSincePublication <= configuration.quickPublishMaxFiles
        return small ? min(configuration.quickQuietPeriod, configuration.quietPeriod) : configuration.quietPeriod
    }

    public mutating func published() {
        firstUnpublishedChangeAt = nil
        nextPublishAttempt = nil
        changedFilesSincePublication = 0
        largeChangePending = false
    }

    public mutating func publicationFailed(at now: ContinuousClock.Instant) {
        nextPublishAttempt = now + configuration.quietPeriod
    }
}

/// The daemon's view of the exclude and include files: the patterns last
/// read from each, nil while a configured file has not been read.
struct FilterFiles: Sendable {
    private var exclude: PatternFileMonitor?
    private var include: PatternFileMonitor?
    /// [] for a file that is not configured.
    private(set) var excludePatterns: [String]?
    private(set) var includePatterns: [String]?

    init(configuration: IndexerConfiguration) {
        exclude = configuration.excludeFile.map { PatternFileMonitor(url: $0, interval: configuration.excludeFileCheckInterval) }
        include = configuration.includeFile.map { PatternFileMonitor(url: $0, interval: configuration.excludeFileCheckInterval) }
        excludePatterns = exclude == nil ? [] : nil
        includePatterns = include == nil ? [] : nil
    }

    var isEmpty: Bool { exclude == nil && include == nil }
    var paths: [String] { [exclude, include].compactMap { $0?.url.path } }

    /// Polls both files. Returns true if a file was read with new contents.
    mutating func poll(at now: ContinuousClock.Instant) -> Bool {
        var changed = false
        if exclude != nil, let patterns = Self.poll(&exclude!, at: now) {
            excludePatterns = patterns
            changed = true
        }
        if include != nil, let patterns = Self.poll(&include!, at: now) {
            includePatterns = patterns
            changed = true
        }
        return changed
    }

    private static func poll(_ monitor: inout PatternFileMonitor, at now: ContinuousClock.Instant) -> [String]? {
        switch monitor.poll(at: now) {
        case .unchanged:
            return nil
        case .failed(let error):
            Log.error("\(monitor.url.path): \(error); keeping the current folder filter")
            return nil
        case .changed(let patterns):
            return patterns
        }
    }
}

/// Notices edits to a pattern file by polling its metadata; the file may
/// live outside the vault, where the FSEvents stream does not reach. Editors
/// that save by rename change the inode, which the signature includes.
struct PatternFileMonitor: Sendable {
    enum Poll: Equatable {
        case unchanged
        case changed([String])
        case failed(String)
    }

    let url: URL
    let interval: Duration
    /// nil until the first poll, so a file edited between startup and the
    /// first check is still read (the caller compares filters, not files).
    private var signature: FileMeta??
    private var lastCheck: ContinuousClock.Instant?

    init(url: URL, interval: Duration) {
        self.url = url
        self.interval = interval
    }

    mutating func poll(at now: ContinuousClock.Instant) -> Poll {
        if let lastCheck, now - lastCheck < interval { return .unchanged }
        lastCheck = now
        var st = stat()
        let current: FileMeta? = stat(url.path, &st) == 0 ? FileMeta(st) : nil
        guard current != signature else { return .unchanged }
        signature = current
        guard current != nil else { return .failed("cannot read the file: \(String(cString: strerror(errno)))") }
        do {
            return .changed(try VaultFilter.patterns(fromFile: url))
        } catch {
            return .failed("\(error)")
        }
    }
}
