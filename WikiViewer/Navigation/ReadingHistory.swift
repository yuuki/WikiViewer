//
//  ReadingHistory.swift
//  WikiViewer
//
//  Where the reader was and what they keep coming back to: recently read
//  notes, pinned notes and the reading position in each note. Kept in
//  UserDefaults, keyed by vault path, so it survives relaunches and
//  generation switches.
//

import Foundation
import Observation
import SwiftUI

struct HistoryEntry: Codable, Hashable, Identifiable {
    var path: String
    var title: String
    var id: String { path }
}

@MainActor
@Observable
final class ReadingHistory {
    /// Notes whose position is remembered.
    static let maxPositions = 300
    static let maxRecents = 50
    /// Notes whose last reading is remembered (learning paths, recall).
    static let maxReadDates = 5_000
    static let defaultsKey = "WikiViewer.readingHistory"

    private struct Stored: Codable {
        var positions: [String: Int] = [:]
        /// Paths in positions, least recently read first (for eviction).
        var positionOrder: [String] = []
        /// Most recently opened first.
        var recents: [HistoryEntry] = []
        var pins: [HistoryEntry] = []
        /// When each note was last opened.
        var readDates: [String: Date] = [:]
        /// Steps of a learning path the reader marked done (true) or not
        /// done (false) by hand, by path note and step note.
        var pathChecks: [String: [String: Bool]] = [:]

        init() {}

        /// Missing keys (data saved by an older build) decode as empty.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            positions = try c.decodeIfPresent([String: Int].self, forKey: .positions) ?? [:]
            positionOrder = try c.decodeIfPresent([String].self, forKey: .positionOrder) ?? []
            recents = try c.decodeIfPresent([HistoryEntry].self, forKey: .recents) ?? []
            pins = try c.decodeIfPresent([HistoryEntry].self, forKey: .pins) ?? []
            readDates = try c.decodeIfPresent([String: Date].self, forKey: .readDates) ?? [:]
            pathChecks = try c.decodeIfPresent([String: [String: Bool]].self, forKey: .pathChecks) ?? [:]
        }
    }

    /// Positions change on every scroll; views only observe the lists.
    @ObservationIgnored private var stored: Stored
    private(set) var recents: [HistoryEntry] = []
    private(set) var pins: [HistoryEntry] = []
    /// Bumped when read dates or path checks change, for views to observe.
    private(set) var readRevision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
        recents = stored.recents
        pins = stored.pins
    }

    func recordVisit(path: String, title: String) {
        var list = stored.recents
        list.removeAll { $0.path == path }
        list.insert(HistoryEntry(path: path, title: title), at: 0)
        stored.recents = Array(list.prefix(Self.maxRecents))
        recents = stored.recents
        stored.readDates[path] = Date()
        if stored.readDates.count > Self.maxReadDates {
            // Forget the notes read longest ago.
            let excess = stored.readDates.count - Self.maxReadDates
            for (old, _) in stored.readDates.sorted(by: { $0.value < $1.value }).prefix(excess) {
                stored.readDates[old] = nil
            }
        }
        readRevision += 1
        // Keep a pinned note's title current too.
        if let i = stored.pins.firstIndex(where: { $0.path == path }), stored.pins[i].title != title {
            stored.pins[i].title = title
            pins = stored.pins
        }
        scheduleSave()
    }

    func removeRecent(_ path: String) {
        stored.recents.removeAll { $0.path == path }
        recents = stored.recents
        scheduleSave()
    }

    func clearRecents() {
        stored.recents = []
        recents = []
        scheduleSave()
    }

    func isPinned(_ path: String) -> Bool {
        pins.contains { $0.path == path }
    }

    func togglePin(path: String, title: String) {
        if isPinned(path) {
            stored.pins.removeAll { $0.path == path }
        } else {
            stored.pins.append(HistoryEntry(path: path, title: title))
        }
        pins = stored.pins
        scheduleSave()
    }

    func movePins(from source: IndexSet, to destination: Int) {
        stored.pins.move(fromOffsets: source, toOffset: destination)
        pins = stored.pins
        scheduleSave()
    }

    /// When the note was last opened, if remembered.
    func lastRead(_ path: String) -> Date? {
        stored.readDates[path]
    }

    /// Whether a step of a learning path is done: as marked by hand, else
    /// whether its note was read.
    func isStepDone(path: String, step: String) -> Bool {
        stored.pathChecks[path]?[step] ?? (stored.readDates[step] != nil)
    }

    func setStepDone(_ done: Bool, path: String, step: String) {
        stored.pathChecks[path, default: [:]][step] = done
        readRevision += 1
        scheduleSave()
    }

    /// Top-level block last at the top of the screen in this note.
    func position(of path: String) -> Int? {
        stored.positions[path]
    }

    func setPosition(_ block: Int?, of path: String) {
        guard stored.positions[path] != block else { return }
        stored.positionOrder.removeAll { $0 == path }
        if let block, block > 0 {
            stored.positions[path] = block
            stored.positionOrder.append(path)
            while stored.positionOrder.count > Self.maxPositions {
                stored.positions[stored.positionOrder.removeFirst()] = nil
            }
        } else {
            // The top of the note needs no entry.
            stored.positions[path] = nil
        }
        scheduleSave()
    }

    /// Scrolling changes positions many times a second; write once it settles.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
