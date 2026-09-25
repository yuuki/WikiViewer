//
//  NoteListModel.swift
//  WikiViewer
//

import Foundation
import Observation

@Observable
final class NoteListModel {
    enum State {
        case loading
        case loaded([NoteSummary])
        case failed(String)
    }

    private(set) var state: State = .loading

    private let openDatabase: () throws -> AppDatabase

    init(openDatabase: @escaping () throws -> AppDatabase = { try AppDatabase.openBundledSample() }) {
        self.openDatabase = openDatabase
    }

    func load() async {
        state = .loading
        do {
            let repository = NoteRepository(database: try openDatabase())
            state = .loaded(try await repository.firstNotes())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
