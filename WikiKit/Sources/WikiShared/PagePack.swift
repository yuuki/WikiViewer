//
//  PagePack.swift
//  WikiShared
//
//  Page-level delta transport ("packs").
//
//  Chunks (ChunkList.swift) are 128 KiB, but an edit dirties individual
//  SQLite pages (8 KiB): a one-note edit changes ~30 pages yet ~25 chunks,
//  so chunk deltas move ~12× more than changed. A pack carries only the
//  changed blocks (one block = one database page), XORed against the base
//  generation's block so unchanged bytes become zeros, and compressed with
//  LZFSE. A pack is a single file, which matters as much as its size: an
//  iCloud Drive or HTTP round trip per file dominates small transfers.
//
//  Two kinds of packs are published (see ArtifactManifest.PackIndex):
//   - a *delta* from a base generation's database to the new one;
//   - a *keyframe*: every block of one generation, not XORed, so a device
//     with nothing installed downloads a compressed database plus one delta
//     instead of thousands of chunks.
//  Both may be split into parts so that no part needs more than
//  `maximumPartRawBytes` of memory to decode.
//
//  Part file format:
//
//      0   4  magic "WVPK"
//      4   1  version (1)
//      5   1  flags: bit 0 = payloads are XORed against the base block,
//                    bit 1 = body stored uncompressed
//      6   2  reserved (0)
//      8   4  blockSize            (UInt32 little-endian)
//     12   4  entry count          (UInt32 LE)
//     16   8  target file size     (UInt64 LE)
//     24   8  raw (decoded) body size (UInt64 LE)
//     32   …  body, LZFSE-compressed unless bit 1 is set
//
//  Decoded body: entries in increasing block order, each
//  `[UInt32 LE block index][payload]`, where the payload length is that
//  block's length in the target file (the last block may be shorter).
//
//  A pack is only a way to move bytes. The file it produces is verified
//  against the manifest (chunk digests or whole-file SHA-256) exactly like
//  one assembled from chunks.
//

import Compression
import Foundation

public enum PagePack {
    public static let magic: [UInt8] = Array("WVPK".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 32
    /// Raw body bytes per part; bounds the memory needed to encode or decode
    /// one part (about twice this, on the phone and on the Mac).
    public static let maximumPartRawBytes = 8 * 1024 * 1024
    /// Upper bound on a part file a reader accepts.
    public static let maximumPartFileBytes: Int64 = Int64(maximumPartRawBytes) + 1024 * 1024
    public static let allowedBlockSizes: Set<Int> = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

    static let flagXOR: UInt8 = 1 << 0
    static let flagStored: UInt8 = 1 << 1

    /// `packs/<first 2 hex>/<sha256>` (content-addressed), or nil if the digest is malformed.
    public static func relativePath(for digest: String) -> String? {
        guard Digest.isValidHex(digest) else { return nil }
        return "packs/\(digest.prefix(2))/\(digest)"
    }

    /// Length of block `index` in a file of `fileSize` bytes (0 past the end).
    public static func blockLength(_ index: Int, blockSize: Int, fileSize: Int64) -> Int {
        let start = Int64(index) * Int64(blockSize)
        guard start < fileSize else { return 0 }
        return Int(min(Int64(blockSize), fileSize - start))
    }

    /// Page size of an SQLite database from its 100-byte header, or nil if
    /// `header` is not one.
    public static func sqlitePageSize(header: Data) -> Int? {
        guard header.count >= 18, header.prefix(16) == Data("SQLite format 3\0".utf8) else { return nil }
        let bytes = [UInt8](header[header.startIndex + 16 ..< header.startIndex + 18])
        let raw = Int(bytes[0]) << 8 | Int(bytes[1])
        let size = raw == 1 ? 65536 : raw
        return allowedBlockSizes.contains(size) ? size : nil
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let m): "Malformed pack: \(m)"
            }
        }
    }

    // MARK: Writing

    /// Accumulates blocks and emits encoded parts of at most
    /// `maximumPartRawBytes` raw bytes each.
    public struct Writer {
        public let blockSize: Int
        public let targetSize: Int64
        public let xor: Bool
        let partRawLimit: Int
        var body = Data()
        /// Compression output and the encoded part, reused across parts: a
        /// keyframe has hundreds of parts, and fresh multi-megabyte buffers of
        /// varying size stay dirty in the allocator's cache after being freed.
        /// A returned part is only valid until the next `append` or `flush`
        /// (it is copied on write if the caller keeps it).
        var scratch = Data()
        var output = Data()
        var entries = 0
        public private(set) var totalRawBytes: Int64 = 0
        public private(set) var totalBlocks = 0

        public init(blockSize: Int, targetSize: Int64, xor: Bool, partRawLimit: Int = PagePack.maximumPartRawBytes) {
            self.blockSize = blockSize
            self.targetSize = targetSize
            self.xor = xor
            self.partRawLimit = max(partRawLimit, blockSize + 4)
            body.reserveCapacity(self.partRawLimit)
        }

        /// Adds one block; returns a finished part when the current one is full.
        /// `payload` must be the block's length in the target file.
        public mutating func append(index: Int, payload: some DataProtocol) -> Data? {
            precondition(payload.count == PagePack.blockLength(index, blockSize: blockSize, fileSize: targetSize))
            var finished: Data?
            if body.count + 4 + payload.count > partRawLimit, entries > 0 {
                finished = flush()
            }
            var le = UInt32(index).littleEndian
            withUnsafeBytes(of: &le) { body.append(contentsOf: $0) }
            body.append(contentsOf: payload)
            entries += 1
            totalBlocks += 1
            totalRawBytes += Int64(4 + payload.count)
            return finished
        }

        /// Emits the pending part, if any.
        public mutating func flush() -> Data? {
            guard entries > 0 else { return nil }
            let part = PagePack.encodePart(body: body, entries: entries, blockSize: blockSize, targetSize: targetSize, xor: xor, scratch: &scratch, output: &output)
            body.removeAll(keepingCapacity: true)
            entries = 0
            return part
        }
    }

    static func encodePart(body: Data, entries: Int, blockSize: Int, targetSize: Int64, xor: Bool, scratch: inout Data, output: inout Data) -> Data {
        if scratch.count < body.count { scratch = Data(count: body.count) }
        let capacity = body.count
        let written = scratch.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, COMPRESSION_LZFSE)
            }
        }
        // Stored as is if LZFSE does not make the body smaller.
        let compressed = written > 0 && written < body.count
        var out = output
        output = Data() // `out` is now the only reference: appends stay in place
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(headerSize + body.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append((xor ? flagXOR : 0) | (compressed ? 0 : flagStored))
        out.append(contentsOf: [0, 0])
        appendLE(&out, UInt32(blockSize))
        appendLE(&out, UInt32(entries))
        appendLE(&out, UInt64(targetSize))
        appendLE(&out, UInt64(body.count))
        if compressed {
            out.append(scratch.prefix(written))
        } else {
            out.append(body)
        }
        output = out
        return out
    }

    static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: Reading

    public struct Part: Sendable {
        public var xor: Bool
        public var blockSize: Int
        public var targetSize: Int64
        public var entryCount: Int
        /// Decoded body (see file format).
        let body: Data

        /// Calls `body` for each entry in order with the block index and its
        /// payload. Entries are validated to be strictly increasing, inside
        /// the target file, and exactly as long as their block.
        public func forEachEntry(_ visit: (Int, Data) throws -> Void) throws {
            var offset = body.startIndex
            var previous = -1
            for _ in 0..<entryCount {
                guard body.endIndex - offset >= 4 else { throw DecodeError.malformed("truncated entry") }
                let index = Int(PagePack.readLE(UInt32.self, body, offset))
                offset += 4
                guard index > previous else { throw DecodeError.malformed("entries out of order") }
                previous = index
                let length = PagePack.blockLength(index, blockSize: blockSize, fileSize: targetSize)
                guard length > 0, body.endIndex - offset >= length else { throw DecodeError.malformed("block \(index) outside target") }
                try visit(index, body[offset ..< offset + length])
                offset += length
            }
            guard offset == body.endIndex else { throw DecodeError.malformed("trailing bytes") }
        }
    }

    /// Parses one part. The decoded size is taken from the header and bounded
    /// by `maximumPartRawBytes`, so a hostile part cannot expand without limit.
    public static func decodePart(_ data: Data, expectedBlockSize: Int, expectedTargetSize: Int64) throws(DecodeError) -> Part {
        guard data.count >= headerSize else { throw .malformed("short header") }
        let base = data.startIndex
        guard Array(data[base ..< base + 4]) == magic else { throw .malformed("magic") }
        guard data[base + 4] == version else { throw .malformed("version \(data[base + 4])") }
        let flags = data[base + 5]
        guard flags & ~(flagXOR | flagStored) == 0, data[base + 6] == 0, data[base + 7] == 0 else { throw .malformed("flags") }
        let blockSize = Int(readLE(UInt32.self, data, base + 8))
        let entries = Int(readLE(UInt32.self, data, base + 12))
        let target = readLE(UInt64.self, data, base + 16)
        let raw = readLE(UInt64.self, data, base + 24)
        guard blockSize == expectedBlockSize, allowedBlockSizes.contains(blockSize) else { throw .malformed("block size \(blockSize)") }
        guard target == UInt64(expectedTargetSize) else { throw .malformed("target size \(target)") }
        guard raw > 0, raw <= UInt64(maximumPartRawBytes), entries > 0, UInt64(entries) * 4 <= raw else { throw .malformed("body size") }
        let payload = data[(base + headerSize)...]
        guard !payload.isEmpty else { throw .malformed("empty body") }
        let body: Data
        if flags & flagStored != 0 {
            guard payload.count == Int(raw) else { throw .malformed("stored body size") }
            body = Data(payload)
        } else {
            guard let out = decompress(payload, rawSize: Int(raw)) else { throw .malformed("compressed body") }
            body = out
        }
        return Part(xor: flags & flagXOR != 0, blockSize: blockSize, targetSize: expectedTargetSize, entryCount: entries, body: body)
    }

    /// Decodes an LZFSE stream that must end exactly after `rawSize` bytes
    /// of output and consume all input (a truncated or padded stream fails).
    static func decompress(_ input: Data, rawSize: Int) -> Data? {
        var out = Data(count: rawSize + 1)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let status: compression_status = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.src_size = input.count
                stream.pointee.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.dst_size = rawSize + 1
                return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }
        }
        let produced = rawSize + 1 - stream.pointee.dst_size
        guard status == COMPRESSION_STATUS_END, produced == rawSize, stream.pointee.src_size == 0 else { return nil }
        out.count = rawSize
        return out
    }

    static func readLE<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, _ offset: Data.Index) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(data[offset + i]) << (8 * i)
        }
        return value
    }

    /// `target = base XOR delta`, with `base` zero-padded or cut to `delta`'s length.
    public static func xor(_ delta: Data, base: Data) -> Data {
        var out = Data(delta)
        let n = min(base.count, out.count)
        guard n > 0 else { return out }
        out.withUnsafeMutableBytes { o in
            base.withUnsafeBytes { b in
                let op = o.bindMemory(to: UInt8.self)
                let bp = b.bindMemory(to: UInt8.self)
                for i in 0..<n { op[i] ^= bp[i] }
            }
        }
        return out
    }
}
