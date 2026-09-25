//
//  ChunkList.swift
//  WikiShared
//
//  Delta transport of database generations.
//
//  A published database is split into fixed-size chunks; each chunk is
//  stored once, content-addressed, as `chunks/<first 2 hex>/<sha256>`. A
//  generation's chunk list names its chunks in order. A device that already
//  has the previous generation reuses every chunk it has locally and fetches
//  only the rest; the reassembled file must still match the manifest's
//  whole-file size and SHA-256 before it is used.
//
//  Measured on a 20k-note vault (BENCHMARKS.md): after a one-note edit 97–99%
//  of chunks are unchanged, so an update transfers megabytes, not the whole
//  database.
//
//  File format (UTF-8 text):
//
//      wikiviewer-chunks 1 <chunkSize> <chunkCount> <totalBytes>
//      <sha256 of chunk 0>
//      <sha256 of chunk 1>
//      …
//

import Foundation

public struct ChunkList: Sendable, Equatable {
    public var chunkSize: Int
    public var totalBytes: Int64
    public var digests: [String]

    public static let defaultChunkSize = 128 * 1024
    public static let allowedChunkSizes: ClosedRange<Int> = (16 * 1024)...(4 * 1024 * 1024)

    public init(chunkSize: Int, totalBytes: Int64, digests: [String]) {
        self.chunkSize = chunkSize
        self.totalBytes = totalBytes
        self.digests = digests
    }

    /// Length of chunk `index` (the last one may be shorter).
    public func length(of index: Int) -> Int {
        let start = Int64(index) * Int64(chunkSize)
        return Int(min(Int64(chunkSize), totalBytes - start))
    }

    public static func relativePath(for digest: String) -> String? {
        guard Digest.isValidHex(digest) else { return nil }
        return "chunks/\(digest.prefix(2))/\(digest)"
    }

    public func encoded() -> Data {
        var text = "wikiviewer-chunks 1 \(chunkSize) \(digests.count) \(totalBytes)\n"
        text.reserveCapacity(text.utf8.count + digests.count * 65)
        for d in digests {
            text += d
            text += "\n"
        }
        return Data(text.utf8)
    }

    public enum DecodeError: Error, Equatable {
        case malformed(String)
    }

    /// Parses and validates a chunk list, including consistency with the
    /// database size announced by the manifest.
    public static func decode(_ data: Data, expectedTotalBytes: Int64) throws(DecodeError) -> ChunkList {
        guard let text = String(data: data, encoding: .utf8) else { throw .malformed("not UTF-8") }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.first else { throw .malformed("empty") }
        let fields = header.split(separator: " ")
        guard fields.count == 5, fields[0] == "wikiviewer-chunks", fields[1] == "1",
              let chunkSize = Int(fields[2]), let count = Int(fields[3]), let total = Int64(fields[4]) else {
            throw .malformed("bad header")
        }
        guard allowedChunkSizes.contains(chunkSize) else { throw .malformed("chunk size \(chunkSize)") }
        guard total == expectedTotalBytes, total > 0 else { throw .malformed("total bytes \(total) != \(expectedTotalBytes)") }
        let expectedCount = Int((total + Int64(chunkSize) - 1) / Int64(chunkSize))
        guard count == expectedCount, lines.count == count + 1 else { throw .malformed("chunk count") }
        var digests: [String] = []
        digests.reserveCapacity(count)
        for line in lines.dropFirst() {
            let d = String(line)
            guard Digest.isValidHex(d) else { throw .malformed("bad digest") }
            digests.append(d)
        }
        return ChunkList(chunkSize: chunkSize, totalBytes: total, digests: digests)
    }

    /// Computes the chunk list of a file by streaming it once.
    public static func make(fileAt url: URL, chunkSize: Int = defaultChunkSize) throws -> (list: ChunkList, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var whole = SHA256Stream()
        var digests: [String] = []
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            whole.update(chunk)
            digests.append(Digest.sha256Hex(chunk))
            total += Int64(chunk.count)
        }
        return (ChunkList(chunkSize: chunkSize, totalBytes: total, digests: digests), whole.finalize())
    }
}

import CryptoKit

/// Incremental SHA-256 producing lowercase hex.
public struct SHA256Stream: Sendable {
    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ data: some DataProtocol) {
        hasher.update(data: data)
    }

    public func finalize() -> String {
        Digest.hex(hasher.finalize())
    }
}
