//
//  ArtifactManifest.swift
//  WikiShared
//

import Foundation

/// `manifest.json`: the current-generation pointer of a published artifact
/// directory. It is written last during publication, so a reader that sees a
/// manifest may still find the database missing (e.g. a partially synced
/// iCloud Drive folder) and must then keep using its previous generation.
///
/// Layout of a published directory:
///
///     manifest.json
///     generations/viewer-000042.sqlite   (optional with chunks + packs)
///     generations/viewer-000042.chunks
///     chunks/ab/ab12…ef                  (content-addressed 128 KiB chunks)
///     packs/ab/ab12…ef                   (content-addressed page packs)
///     assets/ab/ab12…ef.jpg
public struct ArtifactManifest: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var schemaVersion: Int
    public var generation: Int64
    /// ISO-8601 UTC timestamp of publication.
    public var createdAt: String
    public var database: DatabaseEntry
    public var noteCount: Int
    public var assetCount: Int
    public var assets: AssetStoreInfo
    /// Free-form builder identification, e.g. "wikiindex 1".
    public var builder: String
    /// Chunk list for delta transport. When present, `database.path` may be
    /// absent from the published directory (chunks-only publication).
    public var chunks: ChunkListEntry?
    /// Page-level delta packs (see PagePack.swift). Optional: a reader that
    /// finds no usable pack falls back to chunks or the whole database.
    public var packs: PackIndex?

    public struct PackIndex: Codable, Sendable, Equatable {
        /// Block size of every pack (the database page size).
        public var blockSize: Int
        /// A whole database, for devices with nothing to patch.
        public var keyframe: Keyframe?
        /// Deltas from earlier generations' databases to this one.
        public var deltas: [Delta]

        public init(blockSize: Int, keyframe: Keyframe?, deltas: [Delta]) {
            self.blockSize = blockSize
            self.keyframe = keyframe
            self.deltas = deltas
        }

        public struct Keyframe: Codable, Sendable, Equatable {
            /// Generation whose database the keyframe holds. It may be older
            /// than the manifest's: a device then reuses the keyframe's chunks
            /// and fetches only the chunks that changed since.
            public var generation: Int64
            public var byteSize: Int64
            public var sha256: String
            public var parts: [Part]

            public init(generation: Int64, byteSize: Int64, sha256: String, parts: [Part]) {
                self.generation = generation
                self.byteSize = byteSize
                self.sha256 = sha256
                self.parts = parts
            }
        }

        public struct Delta: Codable, Sendable, Equatable {
            /// Whole-file SHA-256 and size of the base database.
            public var baseSHA256: String
            public var baseByteSize: Int64
            /// Changed blocks carried by the parts.
            public var blockCount: Int
            public var parts: [Part]

            public init(baseSHA256: String, baseByteSize: Int64, blockCount: Int, parts: [Part]) {
                self.baseSHA256 = baseSHA256
                self.baseByteSize = baseByteSize
                self.blockCount = blockCount
                self.parts = parts
            }

            public var byteSize: Int64 { parts.reduce(0) { $0 + $1.byteSize } }
        }

        public struct Part: Codable, Sendable, Equatable {
            /// Always `packs/<first 2 hex>/<sha256>`.
            public var path: String
            public var byteSize: Int64
            public var sha256: String

            public init(path: String, byteSize: Int64, sha256: String) {
                self.path = path
                self.byteSize = byteSize
                self.sha256 = sha256
            }
        }

        public static let maximumDeltas = 16
        public static let maximumParts = 1024

        func isValid(for manifest: ArtifactManifest) -> Bool {
            guard PagePack.allowedBlockSizes.contains(blockSize), deltas.count <= Self.maximumDeltas else { return false }
            if let chunks = manifest.chunks, chunks.chunkSize % blockSize != 0 { return false }
            func valid(_ parts: [Part]) -> Bool {
                !parts.isEmpty && parts.count <= Self.maximumParts && parts.allSatisfy { part in
                    PagePack.relativePath(for: part.sha256) == part.path
                        && part.byteSize > PagePack.headerSize && part.byteSize <= PagePack.maximumPartFileBytes
                }
            }
            if let keyframe {
                guard keyframe.generation > 0, keyframe.generation <= manifest.generation,
                      Digest.isValidHex(keyframe.sha256),
                      keyframe.byteSize > 0, keyframe.byteSize <= ArtifactManifest.maximumDatabaseSize,
                      valid(keyframe.parts) else { return false }
                if keyframe.generation == manifest.generation,
                   keyframe.sha256 != manifest.database.sha256 || keyframe.byteSize != manifest.database.byteSize {
                    return false
                }
            }
            return deltas.allSatisfy { delta in
                Digest.isValidHex(delta.baseSHA256) && delta.baseSHA256 != manifest.database.sha256
                    && delta.baseByteSize > 0 && delta.baseByteSize <= ArtifactManifest.maximumDatabaseSize
                    && delta.blockCount > 0 && valid(delta.parts)
            }
        }
    }

    public struct ChunkListEntry: Codable, Sendable, Equatable {
        /// Always `generations/viewer-<generation>.chunks`.
        public var path: String
        public var byteSize: Int64
        public var sha256: String
        public var chunkSize: Int
        public var count: Int

        public init(path: String, byteSize: Int64, sha256: String, chunkSize: Int, count: Int) {
            self.path = path
            self.byteSize = byteSize
            self.sha256 = sha256
            self.chunkSize = chunkSize
            self.count = count
        }
    }

    public struct DatabaseEntry: Codable, Sendable, Equatable {
        /// Relative path, always `generations/viewer-<generation>.sqlite`.
        public var path: String
        public var byteSize: Int64
        /// Lowercase hex SHA-256 of the whole file.
        public var sha256: String

        public init(path: String, byteSize: Int64, sha256: String) {
            self.path = path
            self.byteSize = byteSize
            self.sha256 = sha256
        }
    }

    public struct AssetStoreInfo: Codable, Sendable, Equatable {
        /// Relative directory of the content-addressed store ("assets").
        public var directory: String
        /// "sha256/2" = `<directory>/<first 2 hex>/<sha256>.<ext>`.
        public var layout: String
        /// Total bytes of the asset blobs referenced by this generation.
        public var totalBytes: Int64

        public init(directory: String = "assets", layout: String = AssetStoreInfo.currentLayout, totalBytes: Int64) {
            self.directory = directory
            self.layout = layout
            self.totalBytes = totalBytes
        }

        public static let currentLayout = "sha256/2"
    }

    public init(
        formatVersion: Int = WikiVersions.formatVersion,
        schemaVersion: Int = WikiVersions.schemaVersion,
        generation: Int64,
        createdAt: String,
        database: DatabaseEntry,
        noteCount: Int,
        assetCount: Int,
        assets: AssetStoreInfo,
        builder: String,
        chunks: ChunkListEntry? = nil,
        packs: PackIndex? = nil
    ) {
        self.formatVersion = formatVersion
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.createdAt = createdAt
        self.database = database
        self.noteCount = noteCount
        self.assetCount = assetCount
        self.assets = assets
        self.builder = builder
        self.chunks = chunks
        self.packs = packs
    }

    public static func databasePath(generation: Int64) -> String {
        "generations/" + databaseFileName(generation: generation)
    }

    public static func databaseFileName(generation: Int64) -> String {
        "viewer-" + paddedGeneration(generation) + ".sqlite"
    }

    public static func chunkListPath(generation: Int64) -> String {
        "generations/viewer-" + paddedGeneration(generation) + ".chunks"
    }

    /// Upper bound on a chunk list a reader accepts (≈ 128 GB at 128 KiB chunks).
    public static let maximumChunkListSize: Int64 = 64 * 1024 * 1024

    public static func paddedGeneration(_ generation: Int64) -> String {
        let digits = String(generation)
        return digits.count >= 6 ? digits : String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Upper bound on the manifest size a reader accepts.
    public static let maximumEncodedSize = 64 * 1024
    /// Upper bound on the database size a reader accepts (sanity check).
    public static let maximumDatabaseSize: Int64 = 16 * 1024 * 1024 * 1024

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(Int)
        case unsupportedSchema(Int)
        case invalidGeneration(Int64)
        case invalidDatabasePath(String)
        case invalidDigest(String)
        case invalidSize(Int64)
        case invalidCounts
        case invalidAssetStore
        case invalidChunkList
        case invalidPacks

        public var description: String {
            switch self {
            case .unsupportedFormat(let v): "Unsupported artifact format version \(v)"
            case .unsupportedSchema(let v): "Unsupported database schema version \(v)"
            case .invalidGeneration(let g): "Invalid generation \(g)"
            case .invalidDatabasePath(let p): "Invalid database path \(p)"
            case .invalidDigest(let d): "Invalid SHA-256 digest \(d)"
            case .invalidSize(let s): "Invalid database size \(s)"
            case .invalidCounts: "Invalid note or asset count"
            case .invalidAssetStore: "Invalid asset store description"
            case .invalidChunkList: "Invalid chunk list description"
            case .invalidPacks: "Invalid pack description"
            }
        }
    }

    /// Structural validation. Does not touch the file system.
    public func validate() throws(ValidationError) {
        guard WikiVersions.readableFormatVersions.contains(formatVersion) else {
            throw .unsupportedFormat(formatVersion)
        }
        guard WikiVersions.readableSchemaVersions.contains(schemaVersion) else {
            throw .unsupportedSchema(schemaVersion)
        }
        guard generation > 0, generation < 1_000_000_000 else { throw .invalidGeneration(generation) }
        guard database.path == Self.databasePath(generation: generation) else {
            throw .invalidDatabasePath(database.path)
        }
        guard Digest.isValidHex(database.sha256) else { throw .invalidDigest(database.sha256) }
        guard database.byteSize > 0, database.byteSize <= Self.maximumDatabaseSize else {
            throw .invalidSize(database.byteSize)
        }
        guard noteCount >= 0, assetCount >= 0 else { throw .invalidCounts }
        guard assets.directory == "assets", assets.layout == AssetStoreInfo.currentLayout, assets.totalBytes >= 0 else {
            throw .invalidAssetStore
        }
        if let chunks {
            let expectedCount = (database.byteSize + Int64(chunks.chunkSize) - 1) / Int64(max(chunks.chunkSize, 1))
            guard chunks.path == Self.chunkListPath(generation: generation),
                  Digest.isValidHex(chunks.sha256),
                  ChunkList.allowedChunkSizes.contains(chunks.chunkSize),
                  Int64(chunks.count) == expectedCount,
                  chunks.byteSize > 0, chunks.byteSize <= Self.maximumChunkListSize else {
                throw .invalidChunkList
            }
        }
        if let packs, !packs.isValid(for: self) { throw .invalidPacks }
    }

    /// A reader's view of the manifest: an invalid pack index (e.g. limits a
    /// newer publisher raised) only disables packs, since chunks and the
    /// whole database remain a complete transport.
    public func withoutInvalidPacks() -> ArtifactManifest {
        guard let packs, !packs.isValid(for: self) else { return self }
        var copy = self
        copy.packs = nil
        return copy
    }

    public static func decode(_ data: Data) throws -> ArtifactManifest {
        guard data.count <= maximumEncodedSize else {
            throw ValidationError.invalidSize(Int64(data.count))
        }
        return try JSONDecoder().decode(ArtifactManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Content-addressed asset naming shared by publisher and viewer.
public enum AssetBlobPath {
    /// `assets/ab/ab12…ef.jpg`, or nil if the digest or extension is unsafe.
    public static func relativePath(sha256: String, fileExtension ext: String) -> String? {
        guard Digest.isValidHex(sha256), isSafeExtension(ext) else { return nil }
        let prefix = sha256.prefix(2)
        return "assets/\(prefix)/\(sha256).\(ext)"
    }

    public static func isSafeExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count <= 8 && ext.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
