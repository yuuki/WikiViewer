//
//  Extras.swift
//  IndexerCore
//
//  Data made on the host from the vault by other tools — not notes, but
//  what the app shows beside them. They live in one directory outside the
//  vault (`--extras DIR`), are imported into the builder before each
//  publication (only differing rows are written, so delta packs stay
//  small) and `watch` publishes when they change.
//
//  - `related.jsonl` (#38): a note's neighbours by role, from the vault's
//    wiki-related (scripts/export-related.py writes it). One JSON object
//    per line: {"seed": "<vault path>", "roles": {"<role>": [{"page_path":
//    "<vault path>", "why": "…"}, …]}}.
//
//  A missing file empties its table; a malformed line is skipped.
//

import Foundation
import GRDB
import WikiShared

enum Extras {
    static let signatureKey = "extras_signature"
    static let relatedFile = "related.jsonl"
    /// Files the importer reads, in the signature.
    static let files = [relatedFile]

    static let maximumRelatedPerNote = 12
    static let maximumFileBytes = 64 * 1024 * 1024

    struct Summary: CustomStringConvertible {
        var related = 0
        var written = 0
        var description: String { "extras: \(related) neighbours, \(written) rows written" }
    }

    /// Name, size and modification time of each extras file.
    static func signature(of directory: URL) -> String {
        files.map { name in
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "\(name):-" }
            return "\(name):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
    }

    static func importAll(_ db: Database, from directory: URL) throws -> Summary {
        var summary = Summary()
        (summary.related, summary.written) = try importRelated(db, file: directory.appendingPathComponent(relatedFile))
        try db.execute(sql: "INSERT OR REPLACE INTO builder_state(key, value) VALUES (?, ?)", arguments: [signatureKey, signature(of: directory)])
        return summary
    }

    // MARK: related.jsonl

    struct RelatedLine: Decodable {
        struct Candidate: Decodable {
            var page_path: String
            var why: String?
        }

        var seed: String
        var roles: [String: [Candidate]]
    }

    /// The order roles are stored in when a note has more than the limit.
    static let roleOrder = ["definition", "evidence", "contradiction", "cluster"]

    struct RelatedRow: Hashable {
        var noteID: Int64
        var role: String
        var rank: Int
        var target: Int64
        var why: String?
    }

    static func importRelated(_ db: Database, file: URL) throws -> (Int, Int) {
        var desired = Set<RelatedRow>()
        if let data = try readBounded(file) {
            var ids: [String: Int64] = [:]
            func id(_ path: String) throws -> Int64? {
                if let cached = ids[path] { return cached }
                let found = try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [path])
                ids[path] = found
                return found
            }
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let entry = try? decoder.decode(RelatedLine.self, from: Data(line)),
                      let noteID = try id(entry.seed) else { continue }
                var count = 0
                let roles = entry.roles.keys.sorted { a, b in
                    (roleOrder.firstIndex(of: a) ?? roleOrder.count, a) < (roleOrder.firstIndex(of: b) ?? roleOrder.count, b)
                }
                for role in roles where role.count <= 40 {
                    for (rank, candidate) in (entry.roles[role] ?? []).enumerated() where count < maximumRelatedPerNote {
                        guard let target = try id(candidate.page_path), target != noteID else { continue }
                        desired.insert(RelatedRow(noteID: noteID, role: role, rank: rank, target: target,
                                                  why: candidate.why.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }))
                        count += 1
                    }
                }
            }
        }
        let existing = Set(try Row.fetchAll(db, sql: "SELECT note_id, role, rank, target_note_id, why FROM related").map {
            RelatedRow(noteID: $0["note_id"], role: $0["role"], rank: $0["rank"], target: $0["target_note_id"], why: $0["why"])
        })
        var written = 0
        for row in existing.subtracting(desired) {
            try db.execute(sql: "DELETE FROM related WHERE note_id = ? AND role = ? AND rank = ?", arguments: [row.noteID, row.role, row.rank])
            written += 1
        }
        for row in desired.subtracting(existing) {
            try db.execute(sql: "INSERT OR REPLACE INTO related(note_id, role, rank, target_note_id, why) VALUES (?, ?, ?, ?, ?)",
                           arguments: [row.noteID, row.role, row.rank, row.target, row.why])
            written += 1
        }
        return (desired.count, written)
    }

    /// The file's bytes, nil if it does not exist; refuses oversized files.
    static func readBounded(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else {
            throw IndexerError.invalidConfiguration("\(url.lastPathComponent) is larger than \(maximumFileBytes) bytes")
        }
        return data
    }
}
