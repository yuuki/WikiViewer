//
//  Versions.swift
//  WikiShared
//

/// Version constants shared by the indexer (writer) and the viewer (reader).
///
/// - `formatVersion` covers the artifact layout: manifest fields, directory
///   layout of generations and assets. A reader rejects any format it does
///   not know.
/// - `schemaVersion` covers the SQLite schema of `viewer-<generation>.sqlite`.
///   It is written both to the manifest and to `PRAGMA user_version` so a
///   database file can be checked on its own.
/// - `scannerVersion` identifies the Obsidian syntax scanner. Link ordinals
///   stored in the database are produced by this scanner; the viewer uses the
///   same scanner at render time and falls back to matching by raw text if the
///   versions differ.
public enum WikiVersions {
    public static let formatVersion = 1
    public static let schemaVersion = 3
    public static let scannerVersion = 1

    /// Schema versions this build of the viewer can read.
    public static let readableSchemaVersions: ClosedRange<Int> = 3...3
    /// Artifact format versions this build of the viewer can read.
    public static let readableFormatVersions: ClosedRange<Int> = 1...1
}
