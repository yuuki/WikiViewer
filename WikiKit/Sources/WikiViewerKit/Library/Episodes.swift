//
//  Episodes.swift
//  WikiViewerKit
//
//  Audio episodes (#43): the newest ones from the `episodes` table, and an
//  episode note's chapters — lines like `- [03:12] topic [[Note#Heading]]`
//  (or without brackets) — so the player can say which note the current
//  topic is about.
//

import Foundation
import GRDB
import WikiShared

public struct EpisodeSummary: Sendable, Hashable, Identifiable {
    public var note: NoteSummary
    public var audioAssetID: Int64?
    public var published: String
    public var duration: Int?
    public var id: Int64 { note.id }
}

public struct EpisodeChapter: Sendable, Hashable, Identifiable {
    /// Seconds from the start.
    public var start: Double
    public var title: String
    public var noteID: Int64?
    public var heading: String?
    public var id: Double { start }
}

public enum EpisodeChapters {
    /// Chapters in time order, from the note's body and link rows.
    public static func parse(body: String, links: [OutgoingLink]) -> [EpisodeChapter] {
        var linksByLine: [Int: [OutgoingLink]] = [:]
        for link in links where link.line >= 0 && link.targetNoteID != nil { linksByLine[link.line, default: []].append(link) }
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        guard let pattern = try? Regex(#"^\s*(?:[-*+]|\d+[.)])?\s*\[?((?:\d{1,2}:)?\d{1,2}:\d{2})\]?\s+(.+)$"#) else { return [] }
        var chapters: [EpisodeChapter] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.firstMatch(of: pattern),
                  let time = match.output[1].substring.flatMap({ seconds(String($0)) }),
                  let rest = match.output[2].substring else { continue }
            let link = linksByLine[index]?.first
            // The topic without the note's link ("Alpha の要約 [[Alpha#Summary]]" → "Alpha の要約").
            let detail = LearningPath.detail(of: String(rest), without: link?.raw)
            let title = detail.isEmpty ? LearningPath.readable(String(rest)).trimmingCharacters(in: .whitespacesAndNewlines) : detail
            chapters.append(EpisodeChapter(start: Double(time), title: title, noteID: link?.targetNoteID, heading: link?.heading))
        }
        return chapters.sorted { $0.start < $1.start }
    }

    /// "03:12" or "1:02:03" in seconds.
    public static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }

    /// The chapter playing at `time`.
    public static func current(_ chapters: [EpisodeChapter], at time: Double) -> EpisodeChapter? {
        chapters.last { $0.start <= time + 0.5 }
    }
}

public struct EpisodeRepository: Sendable {
    let database: ViewerDatabase

    public init(database: ViewerDatabase) {
        self.database = database
    }

    /// Newest first (episodes_published).
    public func recent(limit: Int = 10) async throws -> [EpisodeSummary] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.audio_asset_id, e.published, e.duration, n.id, n.title, n.path FROM episodes e
                JOIN notes n ON n.id = e.note_id ORDER BY e.published DESC, e.note_id DESC LIMIT ?
                """, arguments: [clampLimit(limit)]).map(Self.summary)
        }
    }

    public func episode(noteID: Int64) async throws -> EpisodeSummary? {
        try await database.reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT e.audio_asset_id, e.published, e.duration, n.id, n.title, n.path FROM episodes e
                JOIN notes n ON n.id = e.note_id WHERE e.note_id = ?
                """, arguments: [noteID]).map(Self.summary)
        }
    }

    static func summary(_ row: Row) -> EpisodeSummary {
        EpisodeSummary(note: NoteSummary(row: row), audioAssetID: row["audio_asset_id"], published: row["published"], duration: row["duration"])
    }
}
