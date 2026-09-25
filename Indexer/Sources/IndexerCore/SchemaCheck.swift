//
//  SchemaCheck.swift
//  IndexerCore
//
//  The device accepts a database only if its schema matches, object by
//  object, the schema created by ViewerSchema.createStatements
//  (ViewerDatabase.verifySchema). The Mac applies the same rule so a stale
//  builder (same version number, older SQL) is rebuilt and a mismatching
//  snapshot is never published.
//

import GRDB
import WikiShared

enum SchemaCheck {
    static func normalized(_ sql: String?) -> String? {
        sql.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    }

    /// name → (type, normalized SQL) for our own objects.
    static let reference: [String: (String, String?)] = {
        guard let queue = try? DatabaseQueue() else { return [:] }
        return (try? queue.write { db -> [String: (String, String?)] in
            for statement in ViewerSchema.createStatements { try db.execute(sql: statement) }
            var out: [String: (String, String?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE substr(name, 1, 7) != 'sqlite_'") {
                let name: String = row["name"]
                if name.hasPrefix("notes_fts_") && row["type"] == "table" { continue }
                out[name] = (row["type"], normalized(row["sql"]))
            }
            return out
        }) ?? [:]
    }()

    /// A description of the first difference, or nil if the schema matches.
    static func mismatch(_ db: Database) throws -> String? {
        var seen = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE substr(name, 1, 7) != 'sqlite_'") {
            let name: String = row["name"]
            let type: String = row["type"]
            if let expected = reference[name] {
                if expected.0 != type || expected.1 != normalized(row["sql"]) { return "\(name) differs" }
                seen.insert(name)
            } else if !(type == "table" && name.hasPrefix("notes_fts_")) {
                return "unexpected \(type) \(name)"
            }
        }
        if let missing = reference.keys.first(where: { !seen.contains($0) }) { return "missing \(missing)" }
        return nil
    }
}
