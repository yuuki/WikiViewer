//
//  QueryBenchmark.swift
//  WikiViewerKit
//
//  Reproducible latency measurements of the viewer's bounded queries.
//  The same code runs on the macOS host (`wikiindex bench-queries`) and in
//  the iOS Simulator (WikiViewerKitTests, opt-in via environment variable),
//  so numbers are comparable.
//

import Foundation
import GRDB
import WikiShared

public struct QueryBenchmark: Sendable {
    public struct Measurement: Sendable, Codable {
        public var name: String
        public var iterations: Int
        public var minMs: Double
        public var medianMs: Double
        public var p95Ms: Double
        public var maxMs: Double
        public var rows: Int
    }

    public struct Report: Sendable, Codable {
        public var databaseBytes: Int64
        public var noteCount: Int
        public var coldOpenMs: Double
        public var firstQueryMs: Double
        public var footprintAfterOpenBytes: UInt64?
        public var footprintAfterRunBytes: UInt64?
        public var measurements: [Measurement]

        public var markdown: String {
            var lines = [
                "notes \(noteCount), db \(String(format: "%.1f", Double(databaseBytes) / 1_048_576)) MiB, cold open \(String(format: "%.2f", coldOpenMs)) ms, first query \(String(format: "%.2f", firstQueryMs)) ms",
                "",
                "| query | rows | min ms | median ms | p95 ms | max ms |",
                "|---|---:|---:|---:|---:|---:|",
            ]
            for m in measurements {
                lines.append("| \(m.name) | \(m.rows) | \(f(m.minMs)) | \(f(m.medianMs)) | \(f(m.p95Ms)) | \(f(m.maxMs)) |")
            }
            if let a = footprintAfterOpenBytes, let b = footprintAfterRunBytes {
                lines.append("")
                lines.append("phys_footprint after open \(String(format: "%.1f", Double(a) / 1_048_576)) MiB, after run \(String(format: "%.1f", Double(b) / 1_048_576)) MiB")
            }
            return lines.joined(separator: "\n")
        }

        func f(_ v: Double) -> String { String(format: "%.2f", v) }
    }

    public let url: URL
    public var iterations = 30

    public init(url: URL, iterations: Int = 30) {
        self.url = url
        self.iterations = iterations
    }

    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    public func run() async throws -> Report {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var t = ContinuousClock.now
        let db = try ViewerDatabase(url: url, options: .init(immutable: true))
        let coldOpen = Self.ms(t)
        let session = LibrarySession(database: db, installed: nil)
        t = ContinuousClock.now
        _ = try await session.folders.subfolders(of: ViewerSchema.rootFolderID)
        let firstQuery = Self.ms(t)
        let afterOpen = MemoryDiagnostics.physicalFootprint()

        // Benchmark inputs, chosen once (setup queries are not measured).
        let setup: (bigFolder: Int64, hubNote: Int64, sampleNotes: [Int64]) = try await db.reader.read { db in
            let bigFolder = try Int64.fetchOne(db, sql: "SELECT id FROM folders ORDER BY note_count DESC LIMIT 1") ?? 1
            let hub = try Int64.fetchOne(db, sql: "SELECT target_note_id FROM links WHERE target_note_id IS NOT NULL GROUP BY target_note_id ORDER BY count(*) DESC LIMIT 1") ?? 1
            let max = try Int64.fetchOne(db, sql: "SELECT max(id) FROM notes") ?? 1
            var rng = UInt64(42)
            var ids: [Int64] = []
            for _ in 0..<64 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                ids.append(1 + Int64(rng >> 33) % max)
            }
            return (bigFolder, hub, ids)
        }

        var measurements: [Measurement] = []
        func measure(_ name: String, _ body: @Sendable (Int) async throws -> Int) async throws {
            var samples: [Double] = []
            var rows = 0
            _ = try await body(0) // warm-up
            for i in 0..<iterations {
                let start = ContinuousClock.now
                rows = try await body(i)
                samples.append(Self.ms(start))
            }
            samples.sort()
            measurements.append(Measurement(
                name: name, iterations: iterations,
                minMs: samples.first ?? 0,
                medianMs: samples[samples.count / 2],
                p95Ms: samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))],
                maxMs: samples.last ?? 0,
                rows: rows
            ))
        }

        let s = session
        let samples = setup.sampleNotes
        try await measure("root folder: subfolders") { _ in try await s.folders.subfolders(of: ViewerSchema.rootFolderID).items.count }
        try await measure("largest folder: first 200 notes") { _ in try await s.folders.notes(in: setup.bigFolder, limit: 200).items.count }
        try await measure("largest folder: page 2 of 50 (keyset)") { _ in
            let first = try await s.folders.notes(in: setup.bigFolder, limit: 50)
            guard let last = first.items.last else { return 0 }
            return try await s.folders.notes(in: setup.bigFolder, after: TitleCursor(after: last), limit: 50).items.count
        }
        try await measure("quick switcher: prefix 'Note 1'") { _ in try await s.search.quickSwitch("Note 1", limit: 30).count }
        try await measure("quick switcher: infix 'system'") { _ in try await s.search.quickSwitch("system", limit: 30).count }
        try await measure("quick switcher: Japanese 'メモ 12'") { _ in try await s.search.quickSwitch("メモ 12", limit: 30).count }
        try await measure("quick switcher: two common terms 'search note'") { _ in try await s.search.quickSwitch("search note", limit: 30).count }
        try await measure("search: title terms reversed '測定 メモ 627'") { _ in try await s.search.search("測定 メモ 627", limit: 50).count }
        try await measure("FTS: common English 'latency'") { _ in try await s.search.search("latency", limit: 50).count }
        try await measure("FTS: Japanese '全文検索'") { _ in try await s.search.search("全文検索", limit: 50).count }
        try await measure("FTS: two terms 'query budget'") { _ in try await s.search.search("query budget", limit: 50).count }
        try await measure("FTS: rare 'Missing note 77'") { _ in try await s.search.search("Missing note 77", limit: 50).count }
        try await measure("FTS: no match 'zzqxw'") { _ in try await s.search.search("zzqxw", limit: 50).count }
        try await measure("short query fallback '東京'") { _ in try await s.search.search("東京", limit: 50).count }
        try await measure("backlinks: most-linked note (first 100)") { _ in try await s.links.backlinks(to: setup.hubNote, limit: 100).items.count }
        try await measure("backlink count: most-linked note") { _ in try await s.links.backlinkCount(to: setup.hubNote) }
        try await measure("backlinks: random note") { i in try await s.links.backlinks(to: samples[i % samples.count], limit: 100).items.count }
        try await measure("note fetch (body+links+tags)") { i in
            let id = samples[i % samples.count]
            guard let note = try await s.notes.note(id: id) else { return 0 }
            let links = try await s.links.outgoingLinks(of: id)
            let tags = try await s.tags.tags(of: id)
            return note.body.utf8.count > 0 ? links.count + tags.count : 0
        }
        try await measure("note fetch + render") { i in
            let id = samples[i % samples.count]
            guard let note = try await s.notes.note(id: id) else { return 0 }
            let links = try await s.links.outgoingLinks(of: id)
            return await NoteRenderer.renderInBackground(body: note.body, noteID: id, links: links).blocks.count
        }
        try await measure("tags: top 200 by count") { _ in try await s.tags.tags(order: .count, limit: 200).items.count }

        return Report(
            databaseBytes: bytes,
            noteCount: db.generation.noteCount,
            coldOpenMs: coldOpen,
            firstQueryMs: firstQuery,
            footprintAfterOpenBytes: afterOpen,
            footprintAfterRunBytes: MemoryDiagnostics.physicalFootprint(),
            measurements: measurements
        )
    }
}
