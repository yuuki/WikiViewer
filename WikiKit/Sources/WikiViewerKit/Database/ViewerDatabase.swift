//
//  ViewerDatabase.swift
//  WikiViewerKit
//

import Foundation
import GRDB
import WikiShared

/// A read-only connection to one finalized, immutable viewer generation.
///
/// - Opened with `SQLITE_OPEN_READONLY` (GRDB `readonly`).
/// - `PRAGMA query_only = 1` as a second guard against writes.
/// - When `immutable` is true the file is opened through a
///   `file:…?immutable=1` URI (Apple's SQLite is built with SQLITE_USE_URI):
///   SQLite then skips locking and change detection. This is only used for
///   generations inside the app container, which nothing ever modifies.
///   Files in transport locations (iCloud Drive, downloads, staging) are
///   never opened this way.
/// - A bounded page cache and memory-mapped I/O keep resident memory
///   independent of database size (mapped pages are clean and reclaimable).
public final class ViewerDatabase: Sendable {
    public let reader: DatabaseQueue
    /// A second connection used only by full-text search, so a slow search
    /// never delays folder, note or backlink queries (GRDB serializes reads
    /// per queue).
    public let searchReader: DatabaseQueue
    public let url: URL
    public let generation: GenerationInfo

    public struct OpenOptions: Sendable {
        public var immutable: Bool
        public var cacheKiB: Int = 8 * 1024
        public var mmapBytes: Int = 128 * 1024 * 1024

        public init(immutable: Bool) {
            self.immutable = immutable
        }
    }

    public enum OpenError: Error, Equatable, CustomStringConvertible {
        case missingFile
        case unsupportedSchema(Int)
        case missingTable(String)
        case notAViewerDatabase(String)

        public var description: String {
            switch self {
            case .missingFile: "Database file is missing"
            case .unsupportedSchema(let v): "Unsupported database schema version \(v)"
            case .missingTable(let t): "Database is missing table \(t)"
            case .notAViewerDatabase(let m): "Not a WikiViewer database: \(m)"
            }
        }
    }

    public init(url: URL, options: OpenOptions) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpenError.missingFile }
        self.url = url
        var config = Configuration()
        config.readonly = true
        config.label = "viewer"
        config.qos = .userInitiated
        let cacheKiB = options.cacheKiB
        let mmap = options.mmapBytes
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            try db.execute(sql: "PRAGMA cache_size = -\(cacheKiB)")
            try db.execute(sql: "PRAGMA mmap_size = \(mmap)")
        }
        let path = options.immutable ? Self.immutableURI(for: url) : url.path
        reader = try DatabaseQueue(path: path, configuration: config)
        var searchConfig = config
        searchConfig.label = "viewer.search"
        searchReader = try DatabaseQueue(path: path, configuration: searchConfig)
        generation = try reader.read { db in try Self.validateAndLoadInfo(db) }
    }

    /// `file:` URI with percent-encoded path and `immutable=1`.
    static func immutableURI(for url: URL) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file:\(encoded)?immutable=1"
    }

    /// Cheap structural checks run on every open (no full scan). The full
    /// `quick_check` runs once, when a generation is installed.
    static func validateAndLoadInfo(_ db: Database) throws -> GenerationInfo {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard WikiVersions.readableSchemaVersions.contains(version) else { throw OpenError.unsupportedSchema(version) }
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        for table in ViewerSchema.requiredTables where !tables.contains(table) {
            throw OpenError.missingTable(table)
        }
        // Never trap on odd content: first value wins, non-text ignored.
        var meta: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM meta LIMIT 100") {
            if let key = row[0] as String?, let value = row[1] as String?, meta[key] == nil { meta[key] = value }
        }
        guard meta[ViewerSchema.MetaKey.schemaVersion] == String(version) else {
            throw OpenError.notAViewerDatabase("meta schema_version \(meta[ViewerSchema.MetaKey.schemaVersion] ?? "missing")")
        }
        return GenerationInfo(
            generation: Int64(meta[ViewerSchema.MetaKey.generation] ?? "") ?? 0,
            createdAt: meta[ViewerSchema.MetaKey.createdAt] ?? "",
            schemaVersion: version,
            scannerVersion: Int(meta[ViewerSchema.MetaKey.scannerVersion] ?? "") ?? 0,
            noteCount: Int(meta[ViewerSchema.MetaKey.noteCount] ?? "") ?? 0,
            assetCount: Int(meta[ViewerSchema.MetaKey.assetCount] ?? "") ?? 0,
            builder: meta[ViewerSchema.MetaKey.builder] ?? ""
        )
    }

    /// Full validation for a database that has not been trusted yet.
    /// Runs `PRAGMA quick_check` (reads every page once).
    public static func validateUntrusted(at url: URL, expectedSchema: Int, expectedGeneration: Int64, expectedNoteCount: Int) throws {
        var config = Configuration()
        config.readonly = true
        config.label = "validation"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        try queue.read { db in
            // The schema must be exactly the one this build knows: no extra
            // views/triggers, no altered constraints. Together with quick_check
            // (which also verifies NOT NULL constraints) this makes the rows
            // safe to decode.
            try verifySchema(db)
            let check = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard check == ["ok"] else { throw OpenError.notAViewerDatabase("quick_check: \(check.prefix(3).joined(separator: "; "))") }
            let info = try validateAndLoadInfo(db)
            guard info.schemaVersion == expectedSchema else { throw OpenError.unsupportedSchema(info.schemaVersion) }
            guard info.generation == expectedGeneration else {
                throw OpenError.notAViewerDatabase("generation \(info.generation) != manifest \(expectedGeneration)")
            }
            let notes = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? -1
            guard notes == expectedNoteCount else {
                throw OpenError.notAViewerDatabase("note count \(notes) != manifest \(expectedNoteCount)")
            }
        }
    }
}

extension ViewerDatabase {
    struct SchemaObject: Hashable {
        var type: String
        var name: String
        var sql: String?
    }

    static func normalizedSQL(_ sql: String?) -> String? {
        sql.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    }

    /// The schema objects `ViewerSchema.createStatements` produce with this
    /// device's SQLite (built once in memory), split into our own objects
    /// (compared by SQL text) and FTS5 shadow tables (compared by name).
    static let referenceSchema: (objects: [String: SchemaObject], shadowTables: Set<String>) = {
        do {
            let queue = try DatabaseQueue()
            return try queue.write { db in
                for statement in ViewerSchema.createStatements { try db.execute(sql: statement) }
                var objects: [String: SchemaObject] = [:]
                var shadow = Set<String>()
                let created = Set(ViewerSchema.createStatements.compactMap(objectName))
                for row in try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") {
                    let object = SchemaObject(type: row["type"], name: row["name"], sql: normalizedSQL(row["sql"]))
                    if created.contains(object.name) { objects[object.name] = object } else { shadow.insert(object.name) }
                }
                return (objects, shadow)
            }
        } catch {
            return ([:], [])
        }
    }()

    /// Name of the object a CREATE statement creates.
    static func objectName(_ statement: String) -> String? {
        let words = statement.split(whereSeparator: { $0.isWhitespace || $0 == "(" })
        guard let index = words.firstIndex(where: { ["TABLE", "INDEX", "TRIGGER"].contains($0.uppercased()) }), index + 1 < words.count else { return nil }
        return String(words[index + 1])
    }

    static func verifySchema(_ db: Database) throws {
        let reference = referenceSchema
        guard !reference.objects.isEmpty else { throw OpenError.notAViewerDatabase("reference schema unavailable") }
        var seen = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE substr(name, 1, 7) != 'sqlite_' LIMIT 1000") {
            guard let name = row["name"] as String?, let type = row["type"] as String? else {
                throw OpenError.notAViewerDatabase("malformed schema row")
            }
            if let expected = reference.objects[name] {
                guard expected.type == type, expected.sql == normalizedSQL(row["sql"]) else {
                    throw OpenError.notAViewerDatabase("schema object \(name) differs")
                }
            } else if !(type == "table" && (reference.shadowTables.contains(name) || name.hasPrefix("notes_fts_"))) {
                // FTS5 shadow tables are accepted by prefix: their exact set is an
                // SQLite implementation detail that may differ between the
                // publisher's and the device's SQLite versions. They are plain
                // tables (no views/triggers), only read by FTS5 itself.
                throw OpenError.notAViewerDatabase("unexpected schema object \(name)")
            }
            seen.insert(name)
        }
        for name in reference.objects.keys where !seen.contains(name) {
            throw OpenError.missingTable(name)
        }
    }
}

public struct GenerationInfo: Sendable, Equatable {
    public var generation: Int64
    public var createdAt: String
    public var schemaVersion: Int
    public var scannerVersion: Int
    public var noteCount: Int
    public var assetCount: Int
    public var builder: String
}
