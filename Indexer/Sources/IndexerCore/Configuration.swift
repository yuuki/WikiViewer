//
//  Configuration.swift
//  IndexerCore
//

import Foundation
import WikiShared

public struct IndexerConfiguration: Sendable {
    /// Root of the Obsidian vault. Opened strictly read-only.
    public var vault: URL
    /// Holds `builder.sqlite` (mutable, disposable builder state).
    public var stateDirectory: URL
    /// Published artifact directory: `manifest.json`, `generations/`, `assets/`.
    /// May be inside iCloud Drive or served over HTTP(S).
    public var publishDirectory: URL

    /// Longest side of image derivatives, in pixels.
    public var imageMaxDimension: Int = 2048
    /// JPEG quality for derivatives (0…1).
    public var jpegQuality: Double = 0.82
    /// Folders that are never indexed or published (see VaultFilter.swift).
    /// Changing it takes effect on the next reconciliation: newly excluded
    /// files are removed from the builder, newly included ones are indexed.
    public var filter = VaultFilter()
    /// Maximum note size that is indexed; larger files are skipped with a warning.
    public var maximumNoteBytes: Int = 8 * 1024 * 1024
    /// Maximum asset size that is hashed / processed.
    public var maximumAssetBytes: Int = 512 * 1024 * 1024
    /// Concurrent read+parse workers for notes.
    public var parseConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)
    /// Concurrent image decodes/encodes. Kept low: each large image needs a
    /// full-size decode buffer, so this bounds the builder's peak memory.
    public var imageConcurrency: Int = 2
    /// Files per write transaction.
    public var batchSize: Int = 512
    /// Published generations kept in the publish directory.
    public var retainedGenerations: Int = 3
    /// Grace period before an unreferenced asset blob may be deleted.
    public var assetGracePeriod: Duration = .seconds(3600)
    /// Run `PRAGMA integrity_check` (full) instead of `quick_check` before publishing.
    public var fullIntegrityCheck = false
    /// Chunk size for delta transport (see WikiShared/ChunkList.swift).
    public var chunkSize: Int = ChunkList.defaultChunkSize
    /// Also publish the whole database file. Chunks are always published; a
    /// chunks-only publication avoids re-uploading the whole database (e.g.
    /// to iCloud Drive) on every generation.
    public var publishFullDatabase = true

    // Daemon scheduling.
    /// Wait this long after the last file-system event before parsing.
    public var debounce: Duration = .milliseconds(750)
    /// Publish only after the vault has been quiet this long…
    public var quietPeriod: Duration = .seconds(20)
    /// …but never delay a publication longer than this after the first change.
    public var maximumPublicationDelay: Duration = .seconds(300)
    /// Periodic metadata reconciliation (correctness path).
    public var reconciliationInterval: Duration = .seconds(600)
    /// Base delay before retrying a file that was modified while being read.
    public var unstableRetryDelay: Duration = .seconds(2)

    public init(vault: URL, stateDirectory: URL, publishDirectory: URL) {
        self.vault = vault
        self.stateDirectory = stateDirectory
        self.publishDirectory = publishDirectory
    }

    public var builderDatabaseURL: URL { stateDirectory.appendingPathComponent("builder.sqlite") }
    public var assetStoreURL: URL { publishDirectory.appendingPathComponent("assets", isDirectory: true) }

    /// Parameters that affect derivative output; part of the derivative cache key.
    var derivativeParameters: String { "v1;max=\(imageMaxDimension);q=\(Int(jpegQuality * 100))" }

    /// Refuses configurations that could write into the vault or index the
    /// indexer's own output.
    public func validate() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw IndexerError.notADirectory(vault.path)
        }
        for (name, dir) in [("state", stateDirectory), ("publish", publishDirectory)] {
            if dir.isInside(vault) {
                throw IndexerError.unsafeLocation("\(name) directory \(dir.path) is inside the vault; the vault must never be written to")
            }
            if vault.isInside(dir) {
                throw IndexerError.unsafeLocation("vault is inside the \(name) directory \(dir.path)")
            }
        }
    }
}
