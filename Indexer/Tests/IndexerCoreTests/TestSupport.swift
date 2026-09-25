import Foundation
import GRDB
@testable import IndexerCore
import WikiShared

/// Repository-relative fixture vault (read-only in tests; copied when a test mutates it).
let fixtureVault: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // IndexerCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // Indexer
    .deletingLastPathComponent() // repo
    .appendingPathComponent("Fixtures/vault")

final class TempDir {
    let url: URL

    init(_ name: String = "wikiindex-test") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func sub(_ path: String) -> URL { url.appendingPathComponent(path) }
}

/// A test environment with a (possibly copied) vault plus state and publish dirs.
struct Env {
    let tmp: TempDir
    let vault: URL
    var config: IndexerConfiguration

    init(tmp: TempDir, vault: URL, config: IndexerConfiguration) {
        self.tmp = tmp
        self.vault = vault
        self.config = config
    }

    init(copyFixture: Bool, vault explicitVault: URL? = nil) throws {
        Log.setLevel(.error) // keep expected warnings (e.g. the fixture's invalid YAML) out of test output
        tmp = TempDir()
        if let explicitVault {
            vault = explicitVault
        } else if copyFixture {
            vault = tmp.sub("vault")
            try FileManager.default.copyItem(at: fixtureVault, to: vault)
        } else {
            vault = fixtureVault
        }
        config = IndexerConfiguration(vault: vault, stateDirectory: tmp.sub("state"), publishDirectory: tmp.sub("publish"))
        config.parseConcurrency = 4
        config.assetGracePeriod = .zero
    }

    func write(_ path: String, _ text: String) throws {
        let url = vault.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: vault.appendingPathComponent(path))
    }
}

extension Indexer {
    func query<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try builder.writer.read(block)
    }
}

/// Target of the link at `ordinal` in the note at `path`: ("note", path) / ("asset", path) / nil.
func linkTarget(_ db: Database, from path: String, ordinal: Int) throws -> String? {
    let row = try Row.fetchOne(db, sql: """
        SELECT n.path AS note, a.path AS asset FROM links l
        JOIN notes s ON s.id = l.source_note_id
        LEFT JOIN notes n ON n.id = l.target_note_id
        LEFT JOIN assets a ON a.id = l.target_asset_id
        WHERE s.path = ? AND l.ordinal = ?
        """, arguments: [path, ordinal])
    guard let row else { return "<no link>" }
    return (row["note"] as String?) ?? (row["asset"] as String?)
}

/// Resolved target for the first link in `path` whose raw text equals `raw`.
func linkTarget(_ db: Database, from path: String, raw: String) throws -> String? {
    let row = try Row.fetchOne(db, sql: """
        SELECT n.path AS note, a.path AS asset FROM links l
        JOIN notes s ON s.id = l.source_note_id
        LEFT JOIN notes n ON n.id = l.target_note_id
        LEFT JOIN assets a ON a.id = l.target_asset_id
        WHERE s.path = ? AND l.raw = ? ORDER BY l.ordinal LIMIT 1
        """, arguments: [path, raw])
    guard let row else { return "<no link \(raw)>" }
    return (row["note"] as String?) ?? (row["asset"] as String?)
}

/// Snapshot of every file under a directory: path → (size, mtime, sha256).
func treeSnapshot(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])!
    for case let url as URL in e {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        let rel = String(url.path.dropFirst(root.path.count))
        if values.isRegularFile == true {
            result[rel] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0) \(Digest.sha256Hex(try Data(contentsOf: url)))"
        } else {
            result[rel] = "dir \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
    }
    return result
}
