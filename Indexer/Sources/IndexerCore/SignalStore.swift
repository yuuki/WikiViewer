//
//  SignalStore.swift
//  IndexerCore
//
//  Reading signals from the app (#42): which notes were read, for how long
//  and how far, and which are pinned. They are the most reliable record of
//  the reader's interest, and private, so they stay on the Mac, outside the
//  vault, in one directory (`wikiindex requests --signals DIR`):
//
//    reading-YYYY-MM.jsonl   every reading event, one JSON object per line
//                            (with the device and when it arrived)
//    pins-<device>.json      the device's pinned notes, as last sent
//    summary.json            per note over the retention period: reads,
//                            seconds, last read, furthest block, pinned —
//                            what the vault's skills read
//
//  Months older than the retention period are deleted.
//

import Foundation
import WikiShared

public final class SignalStore: Sendable {
    public let directory: URL
    /// Reading events older than this are deleted (whole months).
    public let retention: TimeInterval

    public init(directory: URL, retention: TimeInterval = 180 * 24 * 3600) throws {
        self.directory = directory
        self.retention = retention
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    struct Event: Codable {
        var device: String
        var receivedAt: Date
        var path: String
        var title: String
        var openedAt: Date
        var seconds: Int
        var block: Int?
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func monthFile(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(format: "reading-%04d-%02d.jsonl", c.year ?? 0, c.month ?? 0)
    }

    /// Stores a signals request; returns the number of events stored.
    @discardableResult
    public func append(_ request: HostRequest, now: Date = Date()) throws -> Int {
        let device = Self.safeDeviceName(request.device)
        var byMonth: [String: Data] = [:]
        for signal in request.signals ?? [] {
            let event = Event(device: device, receivedAt: now, path: signal.path, title: signal.title,
                              openedAt: signal.openedAt, seconds: max(0, min(signal.seconds, 24 * 3600)), block: signal.block)
            var line = try Self.encoder.encode(event)
            line.append(0x0A)
            byMonth[Self.monthFile(signal.openedAt), default: Data()].append(line)
        }
        for (name, data) in byMonth {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        if let pins = request.pins {
            try RequestInbox.writeAtomically(try Self.encoder.encode(pins), to: directory.appendingPathComponent("pins-\(device).json"))
        }
        try prune(now: now)
        try writeSummary(now: now)
        return request.signals?.count ?? 0
    }

    /// A device name usable in a file name.
    static func safeDeviceName(_ name: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String((name ?? "device").unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "device" : String(cleaned.prefix(64))
    }

    /// Deletes months entirely older than the retention period.
    func prune(now: Date) throws {
        let oldest = Self.monthFile(now.addingTimeInterval(-retention))
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where name.hasPrefix("reading-") && name.hasSuffix(".jsonl") && name < oldest {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    struct Summary: Codable {
        struct Note: Codable {
            var path: String
            var title: String
            var reads: Int
            var seconds: Int
            /// Nil for a pinned note not read in the period.
            var lastRead: Date?
            var furthestBlock: Int?
            var pinned: Bool
        }

        var generatedAt: Date
        var retentionDays: Int
        var notes: [Note]
    }

    /// Rewrites summary.json from the stored events and pins.
    func writeSummary(now: Date) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var notes: [String: Summary.Note] = [:]
        var pinned = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix("pins-"), name.hasSuffix(".json") {
                pinned.formUnion((try? decoder.decode([String].self, from: Data(contentsOf: url))) ?? [])
                continue
            }
            guard name.hasPrefix("reading-"), name.hasSuffix(".jsonl") else { continue }
            for line in try Data(contentsOf: url).split(separator: 0x0A) {
                guard let event = try? decoder.decode(Event.self, from: Data(line)) else { continue }
                var note = notes[event.path] ?? Summary.Note(path: event.path, title: event.title, reads: 0, seconds: 0,
                                                             lastRead: event.openedAt, furthestBlock: nil, pinned: false)
                note.reads += 1
                note.seconds += event.seconds
                if event.openedAt >= note.lastRead ?? .distantPast {
                    note.lastRead = event.openedAt
                    note.title = event.title
                }
                if let block = event.block { note.furthestBlock = max(note.furthestBlock ?? 0, block) }
                notes[event.path] = note
            }
        }
        for path in pinned {
            notes[path, default: Summary.Note(path: path, title: VaultPath.basename(of: path), reads: 0, seconds: 0,
                                              lastRead: nil, furthestBlock: nil, pinned: true)].pinned = true
        }
        let summary = Summary(generatedAt: now, retentionDays: Int(retention / 86_400),
                              notes: notes.values.sorted { ($0.lastRead ?? .distantPast, $1.path) > ($1.lastRead ?? .distantPast, $0.path) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        try RequestInbox.writeAtomically(try encoder.encode(summary), to: directory.appendingPathComponent("summary.json"))
    }
}
