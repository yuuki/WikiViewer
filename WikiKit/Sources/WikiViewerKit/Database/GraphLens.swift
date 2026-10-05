//
//  GraphLens.swift
//  WikiViewerKit
//
//  The graph as a lens on questions (#39): what each cluster is about and
//  what is still open in it, and the gaps between clusters that the vault's
//  wiki-gap reports name — made on the host (`--extras`), read here a
//  cluster or an overview at a time.
//

import Foundation
import GRDB
import WikiShared

public struct ClusterNote: Sendable, Equatable {
    public var summary: String?
    public var questions: [String]
    public var generatedAt: String?
    /// The cluster's members changed since the summary was written.
    public var isStale: Bool
}

public struct GraphGap: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var noteA: NoteSummary?
    public var noteB: NoteSummary?
    public var clusterA: Int64?
    public var clusterB: Int64?
    public var title: String
    /// The report's reasoning (Markdown).
    public var detail: String
    /// Bridging literature the report recommends.
    public var recommendations: [String]
    /// real-gap, weak, …
    public var verdict: String?
    public var report: NoteSummary?

    /// Between two different clusters (drawn on the overview).
    public var crossesClusters: Bool {
        guard let clusterA, let clusterB else { return false }
        return clusterA != clusterB
    }
}

extension GraphRepository {
    public static let gapLimit = 200

    public func clusterNote(id: Int64) async throws -> ClusterNote? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM graph_cluster_notes WHERE cluster_id = ?", arguments: [id]).map { row in
                let questions = (try? JSONSerialization.jsonObject(with: Data((row["questions"] as String).utf8))) as? [String] ?? []
                return ClusterNote(summary: row["summary"], questions: questions, generatedAt: row["generated_at"], isStale: row["stale"] as Int != 0)
            }
        }
    }

    /// Gaps with at least one side in the cluster.
    public func gaps(touching cluster: Int64) async throws -> [GraphGap] {
        try await database.reader.read { db in
            try Self.gaps(db, sql: """
                SELECT * FROM graph_gaps WHERE cluster_a = ?
                UNION SELECT * FROM graph_gaps WHERE cluster_b = ? ORDER BY id LIMIT 50
                """, arguments: [cluster, cluster])
        }
    }

    /// Gaps between two different clusters, for the overview.
    public func crossClusterGaps() async throws -> [GraphGap] {
        try await database.reader.read { db in
            try Self.gaps(db, sql: """
                SELECT * FROM graph_gaps WHERE cluster_a IS NOT NULL AND cluster_b IS NOT NULL AND cluster_a != cluster_b
                ORDER BY id LIMIT ?
                """, arguments: [Self.gapLimit])
        }
    }

    /// Every gap, newest report first (as stored).
    public func allGaps() async throws -> [GraphGap] {
        try await database.reader.read { db in
            try Self.gaps(db, sql: "SELECT * FROM graph_gaps ORDER BY id LIMIT ?", arguments: [Self.gapLimit])
        }
    }

    static func gaps(_ db: Database, sql: String, arguments: StatementArguments) throws -> [GraphGap] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        var ids = Set<Int64>()
        for row in rows {
            for key in ["note_a", "note_b", "report_note_id"] { if let id = row[key] as Int64? { ids.insert(id) } }
        }
        var notes: [Int64: NoteSummary] = [:]
        if !ids.isEmpty {
            for note in try NoteSummary.fetchAll(db, sql: "SELECT id, title, path FROM notes WHERE id IN (\(placeholders(ids.count)))",
                                                 arguments: StatementArguments(Array(ids))) {
                notes[note.id] = note
            }
        }
        return rows.map { row in
            let recommendations = (try? JSONSerialization.jsonObject(with: Data((row["recommendations"] as String).utf8))) as? [String] ?? []
            return GraphGap(id: row["id"], noteA: (row["note_a"] as Int64?).flatMap { notes[$0] }, noteB: (row["note_b"] as Int64?).flatMap { notes[$0] },
                            clusterA: row["cluster_a"], clusterB: row["cluster_b"], title: row["title"], detail: row["detail"],
                            recommendations: recommendations, verdict: row["verdict"],
                            report: (row["report_note_id"] as Int64?).flatMap { notes[$0] })
        }
    }
}
