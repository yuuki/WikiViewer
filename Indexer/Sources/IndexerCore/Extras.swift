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
//  - `cluster-notes.json` (#39): per cluster of the link graph, a summary
//    and its open questions: {"clusters": [{"id": N, "members": ["<path>",
//    …], "summary": "…", "questions": ["…"], "generated_at": "…"}]}.
//    `members` are the paths the summary was written from; when they no
//    longer overlap the cluster's current most linked notes, the summary
//    is marked stale. The indexer exports the clusters for the tool that
//    writes this file to `<state>/graph-clusters.json`.
//  - `gaps.json` (#39): gap candidates from the vault's wiki-gap reports:
//    {"gaps": [{"title": "…", "sides": ["<note name>", "<note name>"],
//    "detail": "…", "recommendations": ["…"], "verdict": "real-gap",
//    "report": "<vault path>"}]}.
//
//  A missing file empties its table; a malformed line is skipped.
//

import Foundation
import GRDB
import WikiShared

enum Extras {
    static let signatureKey = "extras_signature"
    static let relatedFile = "related.jsonl"
    static let clusterNotesFile = "cluster-notes.json"
    static let gapsFile = "gaps.json"
    /// Written to the state directory for the tools that make the extras.
    static let clusterExportFile = "graph-clusters.json"
    /// Files the importer reads, in the signature.
    static let files = [relatedFile, clusterNotesFile, gapsFile]
    /// Members per cluster in the export, and compared for staleness.
    static let exportedMembers = 40
    static let maximumGaps = 500

    static let maximumRelatedPerNote = 12
    static let maximumFileBytes = 64 * 1024 * 1024

    struct Summary: CustomStringConvertible {
        var related = 0
        var written = 0
        var clusterNotes = 0
        var gaps = 0
        var description: String { "extras: \(related) neighbours, \(clusterNotes) cluster notes, \(gaps) gaps, \(written) rows written" }
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
        summary.clusterNotes = try importClusterNotes(db, file: directory.appendingPathComponent(clusterNotesFile))
        summary.gaps = try importGaps(db, file: directory.appendingPathComponent(gapsFile))
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

    // MARK: Clusters

    /// Each cluster's id, label, size and most linked notes, for the tools
    /// that write `cluster-notes.json`. Rewritten only when it changes.
    static func exportClusters(builder: BuilderDatabase, to url: URL) throws {
        struct Member: Encodable { var path: String; var title: String; var type: String? }
        struct Cluster: Encodable { var id: Int64; var label: String; var size: Int; var members: [Member] }
        struct Export: Encodable { var clusters: [Cluster] }
        let clusters = try builder.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, label, size FROM graph_clusters ORDER BY size DESC, id").map { row in
                let id: Int64 = row["id"]
                let members = try Row.fetchAll(db, sql: """
                    SELECT n.path, n.title, g.type FROM graph_nodes g JOIN notes n ON n.id = g.note_id
                    WHERE g.cluster_id = ? ORDER BY g.weight DESC, n.id LIMIT ?
                    """, arguments: [id, exportedMembers]).map { Member(path: $0["path"], title: $0["title"], type: $0["type"]) }
                return Cluster(id: id, label: row["label"], size: row["size"], members: members)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Export(clusters: clusters))
        if (try? Data(contentsOf: url)) == data { return }
        try RequestInbox.writeAtomically(data, to: url)
    }

    struct ClusterNotesFile: Decodable {
        struct Entry: Decodable {
            var id: Int64
            var members: [String]?
            var summary: String?
            var questions: [String]?
            var generated_at: String?
        }

        var clusters: [Entry]
    }

    /// Fraction of the summary's members still among the cluster's most
    /// linked notes, below which the summary is stale.
    static let staleOverlap = 0.5

    static func importClusterNotes(_ db: Database, file: URL) throws -> Int {
        var rows: [Int64: (summary: String?, questions: String, generated: String?, stale: Int)] = [:]
        if let data = try readBounded(file), let notes = try? JSONDecoder().decode(ClusterNotesFile.self, from: data) {
            for entry in notes.clusters {
                guard try Bool.fetchOne(db, sql: "SELECT 1 FROM graph_clusters WHERE id = ?", arguments: [entry.id]) == true else { continue }
                let current = Set(try String.fetchAll(db, sql: """
                    SELECT n.path FROM graph_nodes g JOIN notes n ON n.id = g.note_id
                    WHERE g.cluster_id = ? ORDER BY g.weight DESC, n.id LIMIT ?
                    """, arguments: [entry.id, exportedMembers]))
                let members = entry.members ?? []
                let overlap = members.isEmpty ? 1 : Double(members.filter(current.contains).count) / Double(members.count)
                let questions = Array((entry.questions ?? []).filter { !$0.isEmpty }.prefix(10)).map { String($0.prefix(500)) }
                let json = String(decoding: (try? JSONSerialization.data(withJSONObject: questions)) ?? Data("[]".utf8), as: UTF8.self)
                let summary = entry.summary.flatMap { $0.isEmpty ? nil : String($0.prefix(4_000)) }
                guard summary != nil || !questions.isEmpty else { continue }
                rows[entry.id] = (summary, json, entry.generated_at, overlap < staleOverlap ? 1 : 0)
            }
        }
        var existing: [Int64: (summary: String?, questions: String, generated: String?, stale: Int)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM graph_cluster_notes") {
            existing[row["cluster_id"]] = (row["summary"], row["questions"], row["generated_at"], row["stale"])
        }
        for id in existing.keys where rows[id] == nil {
            try db.execute(sql: "DELETE FROM graph_cluster_notes WHERE cluster_id = ?", arguments: [id])
        }
        for (id, row) in rows {
            if let old = existing[id], old.summary == row.summary, old.questions == row.questions,
               old.generated == row.generated, old.stale == row.stale { continue }
            try db.execute(sql: "INSERT OR REPLACE INTO graph_cluster_notes(cluster_id, summary, questions, generated_at, stale) VALUES (?, ?, ?, ?, ?)",
                           arguments: [id, row.summary, row.questions, row.generated, row.stale])
        }
        return rows.count
    }

    // MARK: Gaps

    struct GapsFile: Decodable {
        struct Gap: Decodable {
            var title: String
            var sides: [String]
            var detail: String?
            var recommendations: [String]?
            var verdict: String?
            var report: String?
        }

        var gaps: [Gap]
    }

    /// The note a link name ("[[Name]]", "Name", "folder/Name") points to,
    /// by the same key as link resolution (closest folder rules aside).
    static func noteID(named raw: String, _ db: Database) throws -> Int64? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("[["), name.hasSuffix("]]") { name = String(name.dropFirst(2).dropLast(2)) }
        name = String(name.split(separator: "|").first ?? "")
        name = String(name.split(separator: "#").first ?? "")
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        guard !name.isEmpty else { return nil }
        if name.contains("/"), let id = try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [name + ".md"]) {
            return id
        }
        return try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE basename_key = ? ORDER BY length(path), path LIMIT 1",
                                  arguments: [VaultPath.matchKey(VaultPath.basename(of: name))])
    }

    static func importGaps(_ db: Database, file: URL) throws -> Int {
        struct Row6: Hashable {
            var noteA: Int64?, noteB: Int64?, clusterA: Int64?, clusterB: Int64?
            var title: String, detail: String, recommendations: String, verdict: String?, report: Int64?
        }
        var desired: [Row6] = []
        if let data = try readBounded(file), let gaps = try? JSONDecoder().decode(GapsFile.self, from: data) {
            for gap in gaps.gaps.prefix(maximumGaps) where gap.sides.count == 2 {
                let a = try noteID(named: gap.sides[0], db)
                let b = try noteID(named: gap.sides[1], db)
                func cluster(_ id: Int64?) throws -> Int64? {
                    guard let id else { return nil }
                    return try Int64.fetchOne(db, sql: "SELECT cluster_id FROM graph_nodes WHERE note_id = ?", arguments: [id])
                }
                let recommendations = Array((gap.recommendations ?? []).prefix(12)).map { String($0.prefix(300)) }
                let report = try gap.report.flatMap { try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [$0]) }
                desired.append(Row6(noteA: a, noteB: b, clusterA: try cluster(a), clusterB: try cluster(b),
                                    title: String(gap.title.prefix(300)), detail: String((gap.detail ?? "").prefix(4_000)),
                                    recommendations: String(decoding: (try? JSONSerialization.data(withJSONObject: recommendations)) ?? Data("[]".utf8), as: UTF8.self),
                                    verdict: gap.verdict, report: report))
            }
        }
        let existing = try Row.fetchAll(db, sql: "SELECT * FROM graph_gaps ORDER BY id").map {
            Row6(noteA: $0["note_a"], noteB: $0["note_b"], clusterA: $0["cluster_a"], clusterB: $0["cluster_b"],
                 title: $0["title"], detail: $0["detail"], recommendations: $0["recommendations"], verdict: $0["verdict"], report: $0["report_note_id"])
        }
        // Few rows: rewrite the table only when anything differs.
        guard existing != desired else { return desired.count }
        try db.execute(sql: "DELETE FROM graph_gaps")
        for (i, row) in desired.enumerated() {
            try db.execute(sql: """
                INSERT INTO graph_gaps(id, note_a, note_b, cluster_a, cluster_b, title, detail, recommendations, verdict, report_note_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [i + 1, row.noteA, row.noteB, row.clusterA, row.clusterB, row.title, row.detail, row.recommendations, row.verdict, row.report])
        }
        return desired.count
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
