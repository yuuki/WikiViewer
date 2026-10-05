//
//  Library.swift
//  WikiViewerKit
//
//  Main-actor application state: which generation is open, where updates
//  come from, and the generation switch.
//
//  Startup cost is O(1) in vault size: read the `current` pointer, open one
//  SQLite file, run a handful of catalog queries. No notes are loaded.
//

import Foundation
import GRDB
import Observation
import WikiShared

/// Everything a view needs to query one generation. Immutable; a new session
/// is created on every generation switch.
public final class LibrarySession: Sendable, Identifiable {
    public let database: ViewerDatabase
    public let installed: InstalledGeneration?
    public let notes: NoteRepository
    public let folders: FolderRepository
    public let links: LinkRepository
    public let tags: TagRepository
    public let assets: AssetRepository
    public let graph: GraphRepository
    public let bases: BaseRepository
    public let changes: ChangeRepository
    public let related: RelatedRepository
    public let search: any SearchEngine

    public var id: String { installed?.name ?? database.url.path }
    public var info: GenerationInfo { database.generation }

    public init(database: ViewerDatabase, installed: InstalledGeneration?) {
        self.database = database
        self.installed = installed
        notes = NoteRepository(database: database)
        folders = FolderRepository(database: database)
        links = LinkRepository(database: database)
        tags = TagRepository(database: database)
        assets = AssetRepository(database: database)
        graph = GraphRepository(database: database)
        bases = BaseRepository(database: database)
        changes = ChangeRepository(database: database)
        related = RelatedRepository(database: database)
        search = TrigramSearchEngine(database: database)
    }
}

public enum SourceConfiguration: Codable, Sendable, Equatable {
    /// A folder chosen in the Files app (local, iCloud Drive, SMB…), stored
    /// as a security-scoped bookmark.
    case folder(bookmark: Data, displayName: String)
    case http(URL)
    /// The small demo artifact bundled with the app.
    case bundledDemo

    /// Options for a folder bookmark. A macOS sandbox grants access to a
    /// chosen folder across launches only through a security-scoped
    /// bookmark; on iOS every bookmark of a picked folder carries the grant.
    /// Read-write: requests to the Mac are written to the folder's inbox.
    public static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    public var label: String {
        switch self {
        case .folder(_, let name): "Folder: \(name)"
        case .http(let url): url.absoluteString
        case .bundledDemo: "Bundled demo"
        }
    }
}

@MainActor
@Observable
public final class Library {
    public enum State {
        case loading
        case empty
        case ready(LibrarySession)
        case failed(String)
    }

    public enum UpdateStatus: Equatable {
        case idle
        case checking
        case downloading(Int64)
        case upToDate(Date)
        case updated(Int64, Date)
        case failed(String)
    }

    public private(set) var state: State = .loading
    public private(set) var updateStatus: UpdateStatus = .idle
    public private(set) var source: SourceConfiguration?
    public private(set) var lastCheck: Date?

    public let store: GenerationStore
    public let updater: ArtifactUpdater
    public let assetProvider: AssetProvider
    public let imageCache = ImageCache()
    /// Requests to the Mac's Claude waiting on this device.
    public let requests: RequestQueue
    private let defaults: UserDefaults
    private var updateTask: Task<Void, Never>?
    /// Identity of the source the in-flight update uses.
    private var updateSourceID: String?
    private var bootstrapTask: Task<Void, Never>?
    /// The configured source, resolved once per change.
    private var currentSource: (any ArtifactSource)?

    static let sourceKey = "WikiViewer.source"

    public init(store: GenerationStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        updater = ArtifactUpdater(store: store)
        assetProvider = AssetProvider(storeRoot: store.assetsURL)
        requests = RequestQueue(fileURL: store.root.appendingPathComponent("requests.json"))
        if let data = defaults.data(forKey: Self.sourceKey) {
            source = try? JSONDecoder().decode(SourceConfiguration.self, from: data)
        }
        currentSource = makeSource()
    }

    /// Local URL of an asset's blob, fetched from the current source if needed.
    public func blobURL(for asset: AssetInfo) async throws -> URL {
        try await assetProvider.blobURL(for: asset, source: currentSource)
    }

    public var session: LibrarySession? {
        if case .ready(let s) = state { return s }
        return nil
    }

    // MARK: Startup

    /// Opens the current generation, falling back to the previous one (and
    /// then any other installed generation) if it cannot be opened. Update
    /// checks requested while this runs wait for it.
    public func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { await performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        await store.cleanStaging()
        if await openBestInstalled() {
            await store.prune()
            return
        }
        if source == nil, Self.bundledDemoURL != nil {
            setSource(.bundledDemo)
        }
        if source != nil {
            await runUpdate()
        }
        if session == nil, case .loading = state {
            state = .empty
        }
    }

    @discardableResult
    func openBestInstalled() async -> Bool {
        var broken: [InstalledGeneration] = []
        for candidate in await store.openCandidates() {
            do {
                let database = try await Self.open(store.databaseURL(for: candidate))
                let current = await store.currentGeneration()
                if !broken.isEmpty || current != candidate {
                    // Current was unusable: fall back explicitly and never keep
                    // a broken generation as the fallback.
                    try? await store.fallBack(to: candidate, discarding: broken)
                }
                state = .ready(LibrarySession(database: database, installed: candidate))
                return true
            } catch {
                broken.append(candidate)
            }
        }
        return false
    }

    /// Opens off the main actor (file I/O).
    nonisolated static func open(_ url: URL) async throws -> ViewerDatabase {
        try ViewerDatabase(url: url, options: .init(immutable: true))
    }

    // MARK: Sources

    public func setSource(_ configuration: SourceConfiguration?) {
        source = configuration
        save(configuration)
        currentSource = makeSource()
    }

    private func save(_ configuration: SourceConfiguration?) {
        if let configuration, let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.sourceKey)
        } else {
            defaults.removeObject(forKey: Self.sourceKey)
        }
    }

    public nonisolated static var bundledDemoURL: URL? {
        Bundle.module.url(forResource: "DemoArtifact", withExtension: nil)
    }

    /// The transport for `source`. A folder bookmark the system reports as
    /// stale (the folder was moved or renamed) is renewed and saved, so it
    /// keeps resolving.
    private func makeSource() -> (any ArtifactSource)? {
        switch source {
        case nil:
            return nil
        case .bundledDemo:
            return Self.bundledDemoURL.map { LocalFolderArtifactSource(root: $0, acceptsRequests: false) }
        case .http(let url):
            return HTTPArtifactSource(baseURL: url, requestToken: RequestToken.load())
        case .folder(let bookmark, let name):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: SourceConfiguration.bookmarkResolutionOptions,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            if stale, let renewed = Self.renewBookmark(of: url) {
                source = .folder(bookmark: renewed, displayName: name)
                save(source)
            }
            return LocalFolderArtifactSource(root: url, securityScoped: true)
        }
    }

    private nonisolated static func renewBookmark(of url: URL) -> Data? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: Requests

    /// Whether the source can take requests (not the bundled demo).
    public var acceptsRequests: Bool { currentSource?.acceptsRequests ?? false }

    /// Queues a request for the Mac and tries to send it at once; offline,
    /// it is sent by a later sync.
    public func submit(_ request: HostRequest) throws {
        try requests.enqueue(request)
        Task { await syncRequests() }
    }

    /// Sends waiting requests and reads the status of those in progress.
    public func syncRequests() async {
        await requests.sync(source: currentSource)
    }

    /// Replaces the token sent with requests over HTTP.
    public func setRequestToken(_ token: String) {
        RequestToken.save(token)
        currentSource = makeSource()
        Task { await syncRequests() }
    }

    // MARK: Updates

    /// Checks the configured source; if a newer valid generation exists it is
    /// downloaded, validated, installed and switched to. On any failure the
    /// open generation stays in place. Waits for startup to finish first.
    public func checkForUpdates() async {
        await bootstrap()
        await runUpdate()
    }

    /// Keeps the library current while the app is in the foreground; returns
    /// when the calling task is cancelled (e.g. the app leaves the
    /// foreground). Checks once, then waits for the source to announce a
    /// newer generation — at once over an HTTP long poll against
    /// `wikiindex serve`, otherwise by polling the manifest — and updates.
    /// A failed update (e.g. an iCloud Drive folder that is only partly
    /// synced) is retried with exponential backoff instead of waiting for the
    /// next launch.
    public func watchForUpdates() async {
        await checkForUpdates()
        var failures = isFailed ? 1 : 0
        while !Task.isCancelled {
            // Requests ride along with the update cycle: every long poll or
            // poll interval also sends and follows them.
            await syncRequests()
            if failures > 0 {
                guard (try? await Task.sleep(for: Self.retryDelay(afterFailures: failures))) != nil else { return }
            }
            guard let source = currentSource else {
                guard (try? await Task.sleep(for: Self.folderPollInterval)) != nil else { return }
                continue
            }
            let current = await store.currentGeneration()?.generation ?? 0
            do {
                let data = try await source.waitForManifest(after: current, interval: Self.pollInterval(for: source))
                try Task.checkCancellation()
                // Only a different generation is worth an update (it may be
                // lower after the publisher was reset or the source changed).
                if failures > 0 || (try? ArtifactManifest.decode(data).generation) != current {
                    await runUpdate()
                }
                failures = isFailed ? failures + 1 : 0
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = updateStatus { return true }
        return false
    }

    nonisolated static let folderPollInterval: Duration = .seconds(30)
    nonisolated static let httpPollInterval: Duration = .seconds(20)

    nonisolated static func pollInterval(for source: any ArtifactSource) -> Duration {
        source is HTTPArtifactSource ? httpPollInterval : folderPollInterval
    }

    /// 5 s, 10 s, 20 s, … capped at 5 minutes.
    nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(5 * (1 << min(max(failures - 1, 0), 6)), 300))
    }

    /// Runs one update at a time. If an update for the same source is in
    /// flight, waits for it; if the source changed since it started, cancels
    /// it and then checks the new source.
    private func runUpdate() async {
        let sourceID = currentSource?.identifier
        while let running = updateTask {
            if updateSourceID == sourceID {
                await running.value
                return
            }
            running.cancel()
            await running.value
            if updateTask == running {
                updateTask = nil
                updateSourceID = nil
            }
        }
        let task = Task { await performUpdate() }
        updateTask = task
        updateSourceID = sourceID
        // Cancelling the caller (background refresh expiring, the app leaving
        // the foreground) cancels the update; the current generation stays.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if updateTask == task {
            updateTask = nil
            updateSourceID = nil
        }
    }

    private func performUpdate() async {
        guard let source = currentSource else {
            updateStatus = .failed("No update source configured")
            return
        }
        updateStatus = .checking
        lastCheck = Date()
        do {
            switch try await updater.check(source: source, ignoringCurrent: session == nil) {
            case .upToDate:
                updateStatus = .upToDate(Date())
            case .available(let manifest):
                updateStatus = .downloading(manifest.generation)
                let prepared = try await updater.prepare(manifest, source: source)
                try Task.checkCancellation()
                try await switchTo(prepared, lineage: source.identifier)
                updateStatus = .updated(manifest.generation, Date())
            }
        } catch is CancellationError {
            updateStatus = .idle
        } catch {
            updateStatus = .failed(String(describing: error))
        }
    }

    /// The generation switch:
    /// 1. the new generation is fully prepared (validated, in generations/);
    /// 2. it is opened read-only — if that fails, nothing changes;
    /// 3. the `current` pointer is replaced atomically (old → `previous`);
    /// 4. the session is swapped on the main actor; views reload. The old
    ///    connection is released when the last in-flight query finishes; its
    ///    files remain as the fallback generation;
    /// 5. only then are older generations pruned.
    func switchTo(_ prepared: PreparedGeneration, lineage: String) async throws {
        let database: ViewerDatabase
        do {
            database = try await Self.open(prepared.databaseURL)
        } catch {
            await store.discard(prepared.installed)
            throw error
        }
        try Task.checkCancellation()
        try await store.setCurrent(prepared.installed, lineage: lineage)
        state = .ready(LibrarySession(database: database, installed: prepared.installed))
        imageCache.removeAll()
        await store.prune()
        await collectUnreferencedAssets()
    }

    /// Deletes local asset blobs referenced by neither the current nor the
    /// previous generation (bounded by the number of asset rows).
    func collectUnreferencedAssets() async {
        var keep = Set<String>()
        for generation in [await store.currentGeneration(), await store.previousGeneration()].compactMap({ $0 }) {
            guard let database = try? await Self.open(store.databaseURL(for: generation)) else { return }
            guard let names = try? await database.reader.read({ db in
                try String.fetchAll(db, sql: "SELECT DISTINCT blob_sha256 || '.' || blob_ext FROM assets WHERE blob_sha256 IS NOT NULL")
            }) else { return }
            keep.formUnion(names)
        }
        _ = await store.collectAssets(keeping: keep)
    }

    /// Deletes all local generations and assets (derived data only). An
    /// in-flight update is cancelled and awaited first.
    public func resetLocalData() async {
        if let updateTask {
            updateTask.cancel()
            await updateTask.value
        }
        state = .loading
        do {
            try await store.removeAll()
            state = .empty
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
