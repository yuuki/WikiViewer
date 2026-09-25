import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

final class TempDir: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("wikiviewerkit-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func sub(_ path: String) -> URL { url.appendingPathComponent(path) }
}

/// The demo artifact built from Fixtures/vault by the real indexer
/// (scripts/build_demo_artifact.sh).
let demoArtifact: URL = Library.bundledDemoURL!

func demoManifest() throws -> ArtifactManifest {
    try ArtifactManifest.decode(Data(contentsOf: demoArtifact.appendingPathComponent("manifest.json")))
}

func openDemo() throws -> ViewerDatabase {
    let manifest = try demoManifest()
    return try ViewerDatabase(url: demoArtifact.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
}

/// Builds a publish directory derived from the demo artifact. `mutate` runs
/// on a writable copy of the database (test-only; the app never writes).
@discardableResult
func makeArtifact(at dir: URL, generation: Int64, mutate: ((Database) throws -> Void)? = nil, editManifest: ((inout ArtifactManifest) -> Void)? = nil) throws -> ArtifactManifest {
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("generations"), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: dir.appendingPathComponent("assets").path) {
        try fm.copyItem(at: demoArtifact.appendingPathComponent("assets"), to: dir.appendingPathComponent("assets"))
    }
    let demo = try demoManifest()
    let dbPath = ArtifactManifest.databasePath(generation: generation)
    let dbURL = dir.appendingPathComponent(dbPath)
    try? fm.removeItem(at: dbURL)
    try fm.copyItem(at: demoArtifact.appendingPathComponent(demo.database.path), to: dbURL)
    let queue = try DatabaseQueue(path: dbURL.path)
    try queue.write { db in
        try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'generation'", arguments: [String(generation)])
        try mutate?(db)
    }
    try queue.close()
    for suffix in ["-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: dbURL.path + suffix) }
    let (sha, size) = try Digest.sha256Hex(fileAt: dbURL)
    let noteCount = try DatabaseQueue(path: dbURL.path, configuration: { var c = Configuration(); c.readonly = true; return c }()).read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? 0
    }
    var manifest = demo
    manifest.generation = generation
    manifest.database = .init(path: dbPath, byteSize: size, sha256: sha)
    manifest.noteCount = noteCount
    manifest.chunks = nil // derived artifacts are published as whole files only
    editManifest?(&manifest)
    try manifest.encoded().write(to: dir.appendingPathComponent("manifest.json"))
    return manifest
}

/// A source whose manifest/database bytes can be tampered with.
struct ScriptedSource: ArtifactSource {
    var displayName = "scripted"
    var identifier = "scripted"
    var manifest: Data
    var files: [String: URL]
    var truncateTo: Int?

    func fetchManifest() async throws -> Data { manifest }

    func download(_ relativePath: String, to destination: URL, maximumBytes: Int64) async throws {
        try PublishedPath.validate(relativePath)
        guard let url = files[relativePath] else { throw TransportError.notFound(relativePath) }
        var data = try Data(contentsOf: url)
        if let truncateTo { data = data.prefix(truncateTo) }
        guard Int64(data.count) <= maximumBytes else { throw TransportError.tooLarge(relativePath) }
        try data.write(to: destination)
    }
}
