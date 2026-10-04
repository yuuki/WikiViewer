//
//  AssetProvider.swift
//  WikiViewerKit
//
//  Lazily materializes content-addressed asset blobs in the local store and
//  decodes images at display size.
//
//  - Blobs are fetched only when a view asks for them.
//  - Every fetched blob is verified against its SHA-256 before it is moved
//    into the store; a blob in the store is therefore trusted by name.
//  - Concurrent requests for the same blob share one fetch.
//  - Images are decoded with ImageIO thumbnails (kCGImageSourceThumbnailMaxPixelSize)
//    so a 6000×4000 photo never becomes a 96 MB bitmap in memory.
//

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import WikiShared

public actor AssetProvider {
    public nonisolated let storeRoot: URL
    private let defaultSource: (any ArtifactSource)?
    private var inFlight: [String: Task<URL, any Error>] = [:]
    /// Hard cap for a single blob download.
    public static let maximumBlobBytes: Int64 = 128 * 1024 * 1024
    /// Recordings (#43) are larger than images.
    public static let maximumAudioBytes: Int64 = 512 * 1024 * 1024
    /// At most this many blob downloads run at once (fast scrolling through
    /// an image-heavy note must not start dozens of transfers).
    public static let maximumConcurrentFetches = 4
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(storeRoot: URL, source: (any ArtifactSource)? = nil) {
        self.storeRoot = storeRoot
        self.defaultSource = source
    }

    private func acquireSlot() async {
        if activeFetches < Self.maximumConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeFetches -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    public nonisolated func localURL(sha256: String, ext: String) -> URL? {
        guard let relative = AssetBlobPath.relativePath(sha256: sha256, fileExtension: ext) else { return nil }
        // relative = "assets/aa/<sha>.<ext>"; storeRoot is ".../assets".
        return storeRoot.deletingLastPathComponent().appendingPathComponent(relative)
    }

    public enum AssetError: Error, Equatable {
        case noBlob
        case noSource
        case hashMismatch
    }

    /// Returns a local file URL for the asset's blob, fetching it from
    /// `source` (default: the provider's source) if needed.
    public func blobURL(for asset: AssetInfo, source explicitSource: (any ArtifactSource)? = nil) async throws -> URL {
        guard let sha = asset.blobSHA256, let ext = asset.blobExt, let relative = asset.blobRelativePath,
              let local = localURL(sha256: sha, ext: ext) else { throw AssetError.noBlob }
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let task = inFlight[sha] { return try await task.value }
        guard let source = explicitSource ?? defaultSource else { throw AssetError.noSource }
        let cap = asset.kind == .audio ? Self.maximumAudioBytes : Self.maximumBlobBytes
        let maximum = min(asset.blobSize ?? cap, cap)
        let task = Task<URL, any Error> {
            await acquireSlot()
            defer { releaseSlot() }
            try Task.checkCancellation()
            let dir = local.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".\(sha).\(UUID().uuidString).part")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await source.download(relative, to: tmp, maximumBytes: maximum)
            guard try Digest.sha256Hex(fileAt: tmp).hex == sha else { throw AssetError.hashMismatch }
            if !FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.moveItem(at: tmp, to: local)
            }
            return local
        }
        inFlight[sha] = task
        defer { inFlight[sha] = nil }
        return try await task.value
    }
}

/// Decodes images at the size they are displayed.
public enum ImageDownsampler {
    /// Returns an orientation-corrected image whose longest side is at most
    /// `maxPixelSize`, or nil if the file is not a decodable image.
    public static func downsample(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Small LRU of decoded images bounded by total pixel bytes.
public final class ImageCache: Sendable {
    public struct Key: Hashable, Sendable {
        public var sha256: String
        public var maxPixelSize: Int

        public init(sha256: String, maxPixelSize: Int) {
            self.sha256 = sha256
            self.maxPixelSize = maxPixelSize
        }
    }

    private struct State {
        var images: [Key: CGImage] = [:]
        var order: [Key] = []
        var bytes = 0
    }

    private let state = Mutex(State())
    public let limitBytes: Int

    /// Decoded images kept by default: a Mac has memory to spare (and
    /// frees the cache under memory pressure all the same).
    #if os(macOS)
    public static let defaultLimitBytes = 256 * 1024 * 1024
    #else
    public static let defaultLimitBytes = 48 * 1024 * 1024
    #endif

    public init(limitBytes: Int = defaultLimitBytes) {
        self.limitBytes = limitBytes
    }

    public func image(for key: Key) -> CGImage? {
        state.withLock { state in
            guard let image = state.images[key] else { return nil }
            if let i = state.order.firstIndex(of: key) {
                state.order.remove(at: i)
                state.order.append(key)
            }
            return image
        }
    }

    public func insert(_ image: CGImage, for key: Key) {
        let cost = image.bytesPerRow * image.height
        guard cost <= limitBytes else { return }
        state.withLock { state in
            if state.images[key] == nil {
                state.order.append(key)
                state.bytes += cost
            }
            state.images[key] = image
            while state.bytes > limitBytes, let oldest = state.order.first {
                state.order.removeFirst()
                if let evicted = state.images.removeValue(forKey: oldest) {
                    state.bytes -= evicted.bytesPerRow * evicted.height
                }
            }
        }
    }

    public func removeAll() {
        state.withLock { $0 = State() }
    }

    public var totalBytes: Int { state.withLock { $0.bytes } }
}
