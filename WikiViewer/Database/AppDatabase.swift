//
//  AppDatabase.swift
//  WikiViewer
//

import Foundation
import GRDB

/// Read-only access to a note index database.
///
/// The app never writes to the database, so it is always opened with
/// `Configuration.readonly`. A `DatabaseQueue` is used rather than a
/// `DatabasePool` because pools require WAL mode and a writable directory,
/// which the app bundle does not provide.
nonisolated struct AppDatabase: Sendable {
    let reader: any DatabaseReader

    init(reader: any DatabaseReader) {
        self.reader = reader
    }

    /// Opens the sample database shipped inside the app bundle.
    static func openBundledSample(bundle: Bundle = .main) throws -> AppDatabase {
        guard let url = bundle.url(forResource: "sample", withExtension: "sqlite") else {
            throw AppDatabaseError.missingBundledDatabase
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return AppDatabase(reader: queue)
    }
}

nonisolated enum AppDatabaseError: LocalizedError {
    case missingBundledDatabase

    var errorDescription: String? {
        switch self {
        case .missingBundledDatabase:
            "The bundled sample database could not be found."
        }
    }
}
