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
        if let data = defaults.data(forKey: Self.sourceKey) {
            source = try? JSONDecoder().decode(SourceConfiguration.self, from: data)
        }
        currentSource = Self.makeSource(source)
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
        if let configuration, let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.sourceKey)
        } else {
            defaults.removeObject(forKey: Self.sourceKey)
        }
        currentSource = Self.makeSource(configuration)
    }

    public nonisolated static var bundledDemoURL: URL? {
        Bundle.module.url(forResource: "DemoArtifact", withExtension: nil)
    }

    nonisolated static func makeSource(_ configuration: SourceConfiguration?) -> (any ArtifactSource)? {
        switch configuration {
        case nil:
            return nil
        case .bundledDemo:
            return bundledDemoURL.map { LocalFolderArtifactSource(root: $0) }
        case .http(let url):
            return HTTPArtifactSource(baseURL: url)
        case .folder(let bookmark, _):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            return LocalFolderArtifactSource(root: url, securityScoped: true)
        }
    }

    // MARK: Updates

    /// Checks the configured source; if a newer valid generation exists it is
    /// downloaded, validated, installed and switched to. On any failure the
    /// open generation stays in place. Waits for startup to finish first.
    public func checkForUpdates() async {
        await bootstrap()
        await runUpdate()
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
        await task.value
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
            switch try await updater.check(source: source) {
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
