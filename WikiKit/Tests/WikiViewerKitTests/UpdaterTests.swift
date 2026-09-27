import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

@Suite struct UpdaterTests {
    let tmp = TempDir()

    func store() throws -> GenerationStore { try GenerationStore(root: tmp.sub("app/WikiViewer")) }

    /// Installs generation 1 from a folder source and makes it current.
    func installed(_ store: GenerationStore, from dir: URL) async throws -> PreparedGeneration {
        let source = LocalFolderArtifactSource(root: dir)
        let updater = ArtifactUpdater(store: store)
        guard case .available(let manifest) = try await updater.check(source: source) else { throw CancellationError() }
        let prepared = try await updater.prepare(manifest, source: source)
        try await store.setCurrent(prepared.installed, lineage: source.identifier)
        return prepared
    }

    @Test func installsValidGenerationAndDetectsUpToDate() async throws {
        let store = try store()
        let source = LocalFolderArtifactSource(root: demoArtifact)
        let updater = ArtifactUpdater(store: store)
        guard case .available(let manifest) = try await updater.check(source: source) else { Issue.record("expected update"); return }
        let prepared = try await updater.prepare(manifest, source: source)
        try await store.setCurrent(prepared.installed, lineage: source.identifier)
        #expect(try await updater.check(source: source) == .upToDate(current: 1))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: prepared.installed).path).sorted()
        #expect(files == ["manifest.json", "viewer.chunks", "viewer.sqlite"])
        let db = try ViewerDatabase(url: prepared.databaseURL, options: .init(immutable: true))
        #expect(db.generation.noteCount == 11)
        #expect(try await store.stagingIsEmpty())
    }

    /// After a schema change the installed generation cannot be opened; the
    /// same source's generation, rebuilt with the new schema, must then be
    /// installed even though its number is not higher.
    @Test func unopenableCurrentDoesNotCountAsUpToDate() async throws {
        let store = try store()
        let source = LocalFolderArtifactSource(root: demoArtifact)
        let updater = ArtifactUpdater(store: store)
        guard case .available(let manifest) = try await updater.check(source: source) else { Issue.record("expected update"); return }
        let prepared = try await updater.prepare(manifest, source: source)
        try await store.setCurrent(prepared.installed, lineage: source.identifier)
        #expect(try await updater.check(source: source) == .upToDate(current: 1))
        #expect(try await updater.check(source: source, ignoringCurrent: true) == .available(manifest))
    }

    @Test func differentLineageWithSameGenerationNumberIsAccepted() async throws {
        let store = try store()
        _ = try await installed(store, from: demoArtifact)
        let other = tmp.sub("other")
        try makeArtifact(at: other, generation: 1) { db in
            try db.execute(sql: "UPDATE notes SET title = 'Other lineage' WHERE path = 'Home.md'")
        }
        let updater = ArtifactUpdater(store: store)
        guard case .available(let m) = try await updater.check(source: LocalFolderArtifactSource(root: other)) else {
            Issue.record("a new source's generation 1 must not be mistaken for the demo's"); return
        }
        let prepared = try await updater.prepare(m, source: LocalFolderArtifactSource(root: other))
        #expect(await store.installedGenerations().count == 2, "directories are keyed by digest, no collision")
        #expect(prepared.installed.generation == 1)
    }

    func expectRejected(_ source: ScriptedSource, _ check: (any Error) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let store = try store()
        let first = try await installed(store, from: demoArtifact)
        let updater = ArtifactUpdater(store: store)
        do {
            if case .available(let m) = try await updater.check(source: source) {
                _ = try await updater.prepare(m, source: source)
            }
            Issue.record("expected rejection", sourceLocation: sourceLocation)
        } catch {
            #expect(check(error), "unexpected error \(error)", sourceLocation: sourceLocation)
        }
        #expect(await store.currentGeneration() == first.installed, "current generation untouched", sourceLocation: sourceLocation)
        #expect(await store.installedGenerations() == [first.installed], "nothing half-installed", sourceLocation: sourceLocation)
        #expect(try await store.stagingIsEmpty(), "staging cleaned", sourceLocation: sourceLocation)
        // The old generation still opens.
        _ = try ViewerDatabase(url: first.databaseURL, options: .init(immutable: true))
    }

    func source(for dir: URL, manifest: ArtifactManifest) throws -> ScriptedSource {
        ScriptedSource(manifest: try manifest.encoded(), files: [manifest.database.path: dir.appendingPathComponent(manifest.database.path)])
    }

    @Test func rejectsMalformedManifest() async throws {
        let s = ScriptedSource(manifest: Data("{not json".utf8), files: [:])
        try await expectRejected(s) { if case UpdateError.malformedManifest = $0 { true } else { false } }
    }

    @Test func rejectsUnsupportedSchema() async throws {
        let dir = tmp.sub("schema")
        let m = try makeArtifact(at: dir, generation: 2, editManifest: { $0.schemaVersion = 99 })
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidManifest(.unsupportedSchema(99)) = $0 { true } else { false } }
    }

    @Test func rejectsWrongHash() async throws {
        let dir = tmp.sub("hash")
        let m = try makeArtifact(at: dir, generation: 2, editManifest: { $0.database.sha256 = String(repeating: "0", count: 64) })
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.hashMismatch = $0 { true } else { false } }
    }

    @Test func rejectsInterruptedDownload() async throws {
        let dir = tmp.sub("trunc")
        let m = try makeArtifact(at: dir, generation: 2)
        var s = try source(for: dir, manifest: m)
        s.truncateTo = 4096
        try await expectRejected(s) { if case UpdateError.sizeMismatch = $0 { true } else { false } }
    }

    @Test func rejectsOversizedDownload() async throws {
        let dir = tmp.sub("big")
        let m = try makeArtifact(at: dir, generation: 2, editManifest: { $0.database.byteSize -= 1 })
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.transport = $0 { true } else { false } }
    }

    @Test func rejectsMissingDatabase() async throws {
        // Typical for iCloud Drive: manifest synced before the database.
        let dir = tmp.sub("missing")
        let m = try makeArtifact(at: dir, generation: 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(m.database.path))
        try await expectRejected(ScriptedSource(manifest: try m.encoded(), files: [:])) { if case UpdateError.transport = $0 { true } else { false } }
    }

    @Test func rejectsCorruptSQLiteWithMatchingHash() async throws {
        let dir = tmp.sub("corrupt")
        var m = try makeArtifact(at: dir, generation: 2)
        let url = dir.appendingPathComponent(m.database.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 4096 * 2 + 16)
        handle.write(Data(repeating: 0xAB, count: 1500))
        try handle.close()
        // Manifest re-signed over the corrupt bytes: hashing alone can't catch it.
        let (sha, size) = try Digest.sha256Hex(fileAt: url)
        m.database.sha256 = sha
        m.database.byteSize = size
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidDatabase = $0 { true } else { false } }
    }

    @Test func rejectsGenerationMismatchInsideDatabase() async throws {
        let dir = tmp.sub("genmismatch")
        let m = try makeArtifact(at: dir, generation: 2) { db in
            try db.execute(sql: "UPDATE meta SET value = '7' WHERE key = 'generation'")
        }
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidDatabase = $0 { true } else { false } }
    }

    @Test func rejectsMissingTables() async throws {
        let dir = tmp.sub("tables")
        let m = try makeArtifact(at: dir, generation: 2) { db in
            try db.execute(sql: "DROP TABLE blocks")
        }
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidDatabase = $0 { true } else { false } }
    }

    @Test func rejectsAlteredSchema() async throws {
        // Hash-consistent but with an extra view: never accepted.
        let dir = tmp.sub("view")
        let m = try makeArtifact(at: dir, generation: 2) { db in
            try db.execute(sql: "CREATE VIEW evil AS SELECT 1")
        }
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidDatabase = $0 { true } else { false } }
    }

    @Test func rejectsDuplicateMetaWithoutCrashing() async throws {
        let dir = tmp.sub("meta")
        let m = try makeArtifact(at: dir, generation: 2) { db in
            try db.execute(sql: "DROP TABLE meta")
            try db.execute(sql: "CREATE TABLE meta(key TEXT, value TEXT)")
            try db.execute(sql: "INSERT INTO meta VALUES ('schema_version', '1'), ('schema_version', NULL), (NULL, 'x')")
        }
        try await expectRejected(try source(for: dir, manifest: m)) { if case UpdateError.invalidDatabase = $0 { true } else { false } }
    }

    @Test func rejectsTraversalInSources() async throws {
        let src = LocalFolderArtifactSource(root: demoArtifact)
        for bad in ["../x", "/etc/passwd", "generations/../../x", "assets/../manifest.json", ".tmp/x", "state/builder.sqlite"] {
            await #expect(throws: TransportError.self) { try await src.download(bad, to: tmp.sub("x"), maximumBytes: 10) }
        }
    }
}

extension UpdaterTests {
    @Test func interruptedStagingIsCleanedAtLaunch() async throws {
        let store = try store()
        let staging = try await store.makeStagingDirectory()
        try Data("partial".utf8).write(to: staging.appendingPathComponent("viewer.sqlite"))
        await store.cleanStaging()
        #expect(try await store.stagingIsEmpty())
    }

    @Test func pruneKeepsCurrentAndPrevious() async throws {
        let store = try store()
        let g1 = try await installed(store, from: demoArtifact)
        let updater = ArtifactUpdater(store: store)
        var gens = [g1.installed]
        for n in 2...4 {
            let dir = tmp.sub("gen\(n)")
            let m = try makeArtifact(at: dir, generation: Int64(n))
            let src = LocalFolderArtifactSource(root: dir)
            let p = try await updater.prepare(m, source: src)
            try await store.setCurrent(p.installed, lineage: "x")
            gens.append(p.installed)
            await store.prune()
        }
        #expect(await store.installedGenerations() == [gens[3], gens[2]])
        #expect(await store.currentGeneration() == gens[3])
        #expect(await store.previousGeneration() == gens[2])
    }
}

extension GenerationStore {
    func stagingIsEmpty() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: stagingURL.path).isEmpty
    }
}
