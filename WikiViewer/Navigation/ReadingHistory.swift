//
//  ReadingHistory.swift
//  WikiViewer
//
//  Where the reader was: the reading position in each recently read note.
//  Kept in UserDefaults, keyed by vault path, so it survives relaunches and
//  generation switches.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReadingHistory {
    /// Notes whose position is remembered.
    static let maxPositions = 300
    static let defaultsKey = "WikiViewer.readingHistory"

    private struct Stored: Codable {
        var positions: [String: Int] = [:]
        /// Paths in positions, least recently read first (for eviction).
        var positionOrder: [String] = []
    }

    @ObservationIgnored private var stored: Stored
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
