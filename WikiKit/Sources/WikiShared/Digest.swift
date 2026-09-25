//
//  Digest.swift
//  WikiShared
//

import CryptoKit
import Foundation

/// SHA-256 helpers. Files are hashed in fixed-size chunks so hashing a large
/// database never loads it into memory at once.
public enum Digest {
    public static func sha256Hex(_ data: some DataProtocol) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Streams a file through SHA-256. Returns the digest and the byte count.
    public static func sha256Hex(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> (hex: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hex(hasher.finalize()), total)
    }

    public static func hex(_ digest: SHA256.Digest) -> String {
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    public static func isValidHex(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif
