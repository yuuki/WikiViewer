//
//  ArtifactVerifier.swift
//  IndexerCore
//
//  Command-line validation of a publish directory, mirroring the checks the
//  iOS updater performs before accepting a generation.
//

import Foundation
import GRDB
import WikiShared

public struct VerificationReport: Sendable, CustomStringConvertible {
    public var manifest: ArtifactManifest
    public var checkedBlobs: Int
    public var tables: [String: Int]

    public var description: String {
        var lines = [
            "OK generation \(manifest.generation) (schema \(manifest.schemaVersion), format \(manifest.formatVersion))",
            "   database \(manifest.database.path) \(manifest.database.byteSize) bytes sha256 \(manifest.database.sha256)",
            "   notes \(manifest.noteCount), asset blobs \(manifest.assetCount) (\(manifest.assets.totalBytes) bytes, \(checkedBlobs) verified)",
        ]
        for (name, count) in tables.sorted(by: { $0.key < $1.key }) {
            lines.append("   \(name): \(count) rows")
        }
        return lines.joined(separator: "\n")
    }
}

public enum ArtifactVerifier {
    public static func verify(publishDirectory: URL, verifyBlobHashes: Bool = true) throws -> VerificationReport {
        let manifestData = try Data(contentsOf: publishDirectory.appendingPathComponent("manifest.json"))
        let manifest = try ArtifactManifest.decode(manifestData)
        try manifest.validate()
        var dbURL = publishDirectory.appendingPathComponent(manifest.database.path)
        var reassembled: URL?
        defer { if let reassembled { try? FileManager.default.removeItem(at: reassembled) } }
        if let entry = manifest.chunks {
            // Every chunk must exist and match its digest; if the whole
            // database is not published, verify the reassembled file instead.
            let listData = try Data(contentsOf: publishDirectory.appendingPathComponent(entry.path))
            guard Int64(listData.count) == entry.byteSize, Digest.sha256Hex(listData) == entry.sha256 else {
                throw IndexerError.integrityCheckFailed("chunk list hash")
            }
            let list = try ChunkList.decode(listData, expectedTotalBytes: manifest.database.byteSize)
            let wholeFilePublished = FileManager.default.fileExists(atPath: dbURL.path)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("wikiindex-verify-\(UUID().uuidString).sqlite")
            var handle: FileHandle?
            if !wholeFilePublished {
                FileManager.default.createFile(atPath: out.path, contents: nil)
                handle = try FileHandle(forWritingTo: out)
                reassembled = out
            }
            for (i, digest) in list.digests.enumerated() {
                guard let rel = ChunkList.relativePath(for: digest) else { throw IndexerError.integrityCheckFailed("chunk name") }
                let data = try Data(contentsOf: publishDirectory.appendingPathComponent(rel))
                guard data.count == list.length(of: i), Digest.sha256Hex(data) == digest else {
                    throw IndexerError.integrityCheckFailed("chunk \(i) \(digest)")
                }
                try handle?.write(contentsOf: data)
            }
            try handle?.close()
            if !wholeFilePublished { dbURL = out }
        }
        let (sha, size) = try Digest.sha256Hex(fileAt: dbURL)
        guard size == manifest.database.byteSize else { throw IndexerError.integrityCheckFailed("size \(size) != \(manifest.database.byteSize)") }
        guard sha == manifest.database.sha256 else { throw IndexerError.integrityCheckFailed("sha256 mismatch") }

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        defer { try? queue.close() }
        var tables: [String: Int] = [:]
        var checked = 0
        try queue.read { db in
            guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"] else { throw IndexerError.integrityCheckFailed("quick_check") }
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == manifest.schemaVersion else { throw IndexerError.integrityCheckFailed("user_version") }
            if let mismatch = try SchemaCheck.mismatch(db) { throw IndexerError.integrityCheckFailed("schema \(mismatch)") }
            for table in ViewerSchema.requiredTables where table != "notes_fts" {
                tables[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
            }
            guard tables["notes"] == manifest.noteCount else { throw IndexerError.integrityCheckFailed("note count") }
            for table in ViewerSchema.builderOnlyTables {
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0 else { throw IndexerError.integrityCheckFailed("\(table) not empty") }
            }
            let blobs = try Row.fetchAll(db, sql: "SELECT DISTINCT blob_sha256, blob_ext FROM assets WHERE blob_sha256 IS NOT NULL")
            for row in blobs {
                let blobSHA: String = row[0]
                let ext: String = row[1]
                guard let rel = AssetBlobPath.relativePath(sha256: blobSHA, fileExtension: ext) else { throw IndexerError.integrityCheckFailed("unsafe blob name") }
                let url = publishDirectory.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { throw IndexerError.integrityCheckFailed("missing blob \(rel)") }
                if verifyBlobHashes {
                    guard try Digest.sha256Hex(fileAt: url).hex == blobSHA else { throw IndexerError.integrityCheckFailed("blob hash \(rel)") }
                }
                checked += 1
            }
        }
        return VerificationReport(manifest: manifest, checkedBlobs: checked, tables: tables)
    }
}
