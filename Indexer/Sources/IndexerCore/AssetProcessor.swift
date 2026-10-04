//
//  AssetProcessor.swift
//  IndexerCore
//
//  Hashes vault attachments and produces viewer-oriented image blobs in the
//  content-addressed store `assets/<first 2 hex>/<sha256>.<ext>`.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WikiShared

/// Content-addressed blob store. Blobs are immutable: a blob is written to a
/// temporary name and renamed into place, and never modified afterwards.
public struct AssetStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(sha256: String, ext: String) -> URL? {
        guard let relative = AssetBlobPath.relativePath(sha256: sha256, fileExtension: ext) else { return nil }
        // relative is "assets/aa/…"; root already is ".../assets".
        return root.deletingLastPathComponent().appendingPathComponent(relative)
    }

    public func contains(sha256: String, ext: String) -> Bool {
        guard let url = url(sha256: sha256, ext: ext) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Copies the file at `source` under its digest unless it already
    /// exists (streamed: a long recording never sits in memory).
    public func putFile(_ source: URL, sha256: String, ext: String) throws {
        guard let url = url(sha256: sha256, ext: ext) else { throw IndexerError.publicationFailed("unsafe blob name \(sha256).\(ext)") }
        if FileManager.default.fileExists(atPath: url.path) { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(sha256).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: tmp)
            // The copy must be the bytes that were hashed.
            guard try Digest.sha256Hex(fileAt: tmp).hex == sha256 else {
                throw IndexerError.publicationFailed("\(source.lastPathComponent) changed while it was copied")
            }
            try fsyncPath(tmp)
            try atomicRename(tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Writes `data` under its digest unless it already exists.
    public func put(_ data: Data, sha256: String, ext: String) throws {
        guard let url = url(sha256: sha256, ext: ext) else { throw IndexerError.publicationFailed("unsafe blob name \(sha256).\(ext)") }
        if FileManager.default.fileExists(atPath: url.path) { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(sha256).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try fsyncPath(tmp)
        do {
            try atomicRename(tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

public struct AssetOutcome: Sendable {
    public var meta: FileMeta
    public var sourceSHA256: String
    public var blob: AssetBlobInfo?
    /// True if a derivative was produced now (for the derivative cache).
    public var producedDerivative: Bool
    /// The text of a `.base` file, which the builder evaluates.
    public var text: String?
}

public enum AssetProcessor {
    /// Largest original shipped unchanged (small, already web-friendly images).
    static let passthroughMaximumBytes = 4 * 1024 * 1024
    static let maximumImageBytes = 96 * 1024 * 1024

    public enum Result: Sendable {
        case processed(AssetOutcome)
        case unstable
        case missing
        case failed(String)
    }

    public static func process(
        vault: URL,
        path: String,
        kind: ViewerSchema.AssetKind,
        configuration: IndexerConfiguration,
        store: AssetStore,
        cachedDerivative: (String) -> AssetBlobInfo?
    ) -> Result {
        if kind == .base {
            switch StableReader.read(vault: vault, relativePath: path, maximumBytes: BaseDefinition.maximumBytes) {
            case .missing: return .missing
            case .unstable: return .unstable
            case .failed(let e): return .failed(e)
            case .tooLarge(let meta): return .failed("\(meta.size) bytes exceeds the base size limit")
            case .stable(let data, let meta):
                return .processed(AssetOutcome(meta: meta, sourceSHA256: Digest.sha256Hex(data), blob: nil, producedDerivative: false, text: String(decoding: data, as: UTF8.self)))
            }
        }
        if kind == .audio {
            return audio(vault: vault, path: path, configuration: configuration, store: store)
        }
        guard kind == .image else {
            // PDFs and video: metadata only for now (the viewer shows a
            // placeholder). Hash by streaming so large media never sits in memory.
            return hashOnly(vault: vault, path: path, maximumBytes: configuration.maximumAssetBytes)
        }
        switch StableReader.read(vault: vault, relativePath: path, maximumBytes: maximumImageBytes) {
        case .missing: return .missing
        case .unstable: return .unstable
        case .failed(let e): return .failed(e)
        case .tooLarge:
            return hashOnly(vault: vault, path: path, maximumBytes: configuration.maximumAssetBytes)
        case .stable(let data, let meta):
            let sha = Digest.sha256Hex(data)
            if let cached = cachedDerivative(sha), store.contains(sha256: cached.sha256, ext: cached.ext) {
                return .processed(AssetOutcome(meta: meta, sourceSHA256: sha, blob: cached, producedDerivative: false))
            }
            let ext = VaultPath.fileExtension(of: path)
            do {
                let blob = try makeBlob(data: data, sourceSHA256: sha, sourceExtension: ext, configuration: configuration, store: store)
                return .processed(AssetOutcome(meta: meta, sourceSHA256: sha, blob: blob, producedDerivative: blob != nil))
            } catch {
                Log.warning("asset \(path): derivative failed: \(error)")
                return .processed(AssetOutcome(meta: meta, sourceSHA256: sha, blob: nil, producedDerivative: false))
            }
        }
    }

    /// Audio (#43) is published as it is, under its own digest, up to
    /// `audioMaximumBytes`; the app streams it to disk and plays it.
    static func audio(vault: URL, path: String, configuration: IndexerConfiguration, store: AssetStore) -> Result {
        let hashed = hashOnly(vault: vault, path: path, maximumBytes: configuration.maximumAssetBytes)
        guard case .processed(var outcome) = hashed, configuration.audioMaximumBytes > 0,
              outcome.meta.size <= Int64(configuration.audioMaximumBytes) else { return hashed }
        let ext = VaultPath.fileExtension(of: path)
        guard ["m4a", "mp3", "aac", "wav"].contains(ext) else { return hashed }
        do {
            if !store.contains(sha256: outcome.sourceSHA256, ext: ext) {
                try store.putFile(URL(fileURLWithPath: vault.canonicalPath + "/" + path), sha256: outcome.sourceSHA256, ext: ext)
            }
            outcome.blob = AssetBlobInfo(sha256: outcome.sourceSHA256, ext: ext, size: outcome.meta.size, width: nil, height: nil)
            return .processed(outcome)
        } catch {
            Log.warning("asset \(path): \(error)")
            return .unstable
        }
    }

    static func hashOnly(vault: URL, path: String, maximumBytes: Int) -> Result {
        let fullPath = vault.canonicalPath + "/" + path
        let fd = open(fullPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT || errno == ELOOP ? .missing : .failed(String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard openedFileMatches(fd: fd, vault: vault, relativePath: path) else { return .missing }
        var a = stat()
        guard fstat(fd, &a) == 0, a.st_mode & S_IFMT == S_IFREG else { return .missing }
        let metaA = FileMeta(a)
        guard metaA.size <= Int64(maximumBytes) else {
            // Too large to hash in reasonable time; identify by metadata.
            return .processed(AssetOutcome(meta: metaA, sourceSHA256: Digest.sha256Hex(Data("\(path):\(metaA.size):\(metaA.mtimeNs)".utf8)), blob: nil, producedDerivative: false))
        }
        var hasher = Hasher256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        var b = stat()
        fstat(fd, &b)
        var c = stat()
        guard lstat(fullPath, &c) == 0, FileMeta(b) == metaA, FileMeta(c) == metaA else { return .unstable }
        return .processed(AssetOutcome(meta: metaA, sourceSHA256: hasher.finalize(), blob: nil, producedDerivative: false))
    }

    /// Produces the blob the viewer downloads for an image: the original when
    /// it is small and web-friendly, else a downsampled, orientation-corrected
    /// JPEG (opaque) or PNG (with alpha).
    static func makeBlob(data: Data, sourceSHA256: String, sourceExtension: String, configuration: IndexerConfiguration, store: AssetStore) throws -> AssetBlobInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil // Undecodable (e.g. SVG): metadata only.
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = orientation >= 5 && orientation <= 8
        let displayWidth = rotated ? pixelHeight : pixelWidth
        let displayHeight = rotated ? pixelWidth : pixelHeight
        let longest = max(pixelWidth, pixelHeight)

        let passthroughTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        if longest <= configuration.imageMaxDimension, data.count <= passthroughMaximumBytes, passthroughTypes.contains(sourceExtension) {
            let ext = sourceExtension == "jpeg" ? "jpg" : sourceExtension
            try store.put(data, sha256: sourceSHA256, ext: ext)
            return AssetBlobInfo(sha256: sourceSHA256, ext: ext, size: Int64(data.count), width: displayWidth, height: displayHeight)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(configuration.imageMaxDimension, longest),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var destOptions: [CFString: Any] = [:]
        if !hasAlpha { destOptions[kCGImageDestinationLossyCompressionQuality] = configuration.jpegQuality }
        CGImageDestinationAddImage(destination, image, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let blobData = out as Data
        let blobSHA = Digest.sha256Hex(blobData)
        let ext = hasAlpha ? "png" : "jpg"
        try store.put(blobData, sha256: blobSHA, ext: ext)
        return AssetBlobInfo(sha256: blobSHA, ext: ext, size: Int64(blobData.count), width: image.width, height: image.height)
    }
}

/// Small wrapper so streaming hashing reads naturally.
struct Hasher256 {
    private var inner = CryptoKitSHA256()
    mutating func update(_ data: Data) { inner.update(data: data) }
    func finalize() -> String { Digest.hex(inner.finalize()) }
}

import CryptoKit
typealias CryptoKitSHA256 = SHA256
