//
//  Episodes.swift
//  IndexerCore
//
//  Audio episodes (#43, #44): a note with `type: episode` that links or
//  embeds the recording it is about, usually written by the podcast tool
//  with its chapters as `- [mm:ss] topic [[Note#Heading]]` lines. The
//  table lets the app list the newest episodes with one indexed read; the
//  chapters are read from the note itself when it is opened.
//
//    ---
//    type: episode
//    audio: "[[2026-10-04 今日の回.m4a]]"
//    date: 2026-10-04
//    duration: 1234        # seconds, or "20:34"
//    ---
//

import Foundation
import GRDB
import WikiShared

enum Episodes {
    /// Rebuilds the table, writing only rows that differ. Returns the
    /// number of episodes.
    @discardableResult
    static func rebuild(_ db: Database) throws -> Int {
        struct Row8: Equatable { var audio: Int64?; var published: String; var duration: Int? }
        var desired: [Int64: Row8] = [:]
        // Only notes whose frontmatter mentions "episode" are parsed.
        for row in try Row.fetchAll(db, sql: "SELECT id, frontmatter, mtime_ns FROM notes WHERE frontmatter LIKE '%episode%'") {
            let fields = ChangeLog.scalarFields(frontmatterJSON: row["frontmatter"])
            guard fields["type"]?.lowercased() == "episode" else { continue }
            let id: Int64 = row["id"]
            let audio = try Int64.fetchOne(db, sql: """
                SELECT l.target_asset_id FROM links l JOIN assets a ON a.id = l.target_asset_id
                WHERE l.source_note_id = ? AND a.kind = ? ORDER BY l.line < 0 DESC, l.ordinal LIMIT 1
                """, arguments: [id, ViewerSchema.AssetKind.audio.rawValue])
            let date = (fields["date"] ?? fields["published"] ?? fields["created"]).map { String($0.prefix(10)) }
                ?? Self.day(nanoseconds: row["mtime_ns"])
            desired[id] = Row8(audio: audio, published: date, duration: fields["duration"].flatMap(Self.seconds))
        }
        var existing: [Int64: Row8] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM episodes") {
            existing[row["note_id"]] = Row8(audio: row["audio_asset_id"], published: row["published"], duration: row["duration"])
        }
        for id in existing.keys where desired[id] == nil {
            try db.execute(sql: "DELETE FROM episodes WHERE note_id = ?", arguments: [id])
        }
        for (id, row) in desired where existing[id] != row {
            try db.execute(sql: "INSERT OR REPLACE INTO episodes(note_id, audio_asset_id, published, duration) VALUES (?, ?, ?, ?)",
                           arguments: [id, row.audio, row.published, row.duration])
        }
        return desired.count
    }

    /// "1234", "20:34" or "1:02:03" in seconds.
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }

    static func day(nanoseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(nanoseconds) / 1e9)
        return date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}
