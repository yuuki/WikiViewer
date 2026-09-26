import Foundation
import Testing
@testable import WikiShared

struct PagePackTests {
    func block(_ seed: UInt8, _ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0 / 7) })
    }

    func entries(_ part: PagePack.Part) throws -> [(Int, Data)] {
        var out: [(Int, Data)] = []
        try part.forEachEntry { out.append(($0, Data($1))) }
        return out
    }

    @Test func roundTripAcrossPartsWithShortLastBlock() throws {
        let blockSize = 1024
        let targetSize: Int64 = 10 * 1024 + 300 // 11 blocks, the last 300 bytes
        var writer = PagePack.Writer(blockSize: blockSize, targetSize: targetSize, xor: false, partRawLimit: 3 * (blockSize + 4))
        var parts: [Data] = []
        var expected: [(Int, Data)] = []
        for index in [0, 2, 3, 7, 9, 10] {
            let payload = block(UInt8(index), PagePack.blockLength(index, blockSize: blockSize, fileSize: targetSize))
            expected.append((index, payload))
            if let part = writer.append(index: index, payload: payload) { parts.append(part) }
        }
        if let part = writer.flush() { parts.append(part) }
        #expect(parts.count == 2, "split at the raw limit")
        #expect(writer.totalBlocks == 6)
        var decoded: [(Int, Data)] = []
        for data in parts {
            let part = try PagePack.decodePart(data, expectedBlockSize: blockSize, expectedTargetSize: targetSize)
            #expect(!part.xor)
            decoded += try entries(part)
        }
        #expect(decoded.map(\.0) == expected.map(\.0))
        #expect(decoded.map(\.1) == expected.map(\.1))
        #expect(decoded.last?.1.count == 300)
    }

    @Test func compressesRepetitiveBlocks() throws {
        var writer = PagePack.Writer(blockSize: 8192, targetSize: 8192 * 4, xor: true)
        for i in 0..<4 { _ = writer.append(index: i, payload: Data(repeating: 0, count: 8190) + Data([1, 2])) }
        let flushed = writer.flush()
        let data = try #require(flushed)
        #expect(data.count < 1024, "zeros from XOR compress well: \(data.count) bytes")
        let part = try PagePack.decodePart(data, expectedBlockSize: 8192, expectedTargetSize: 8192 * 4)
        #expect(part.xor)
        #expect(try entries(part).count == 4)
    }

    @Test func incompressibleBodyIsStored() throws {
        var rng = SystemRandomNumberGenerator()
        let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        var writer = PagePack.Writer(blockSize: 4096, targetSize: 4096, xor: false)
        _ = writer.append(index: 0, payload: noise)
        let flushed = writer.flush()
        let data = try #require(flushed)
        let part = try PagePack.decodePart(data, expectedBlockSize: 4096, expectedTargetSize: 4096)
        #expect(try entries(part).first?.1 == noise)
    }

    @Test func xorRestoresTarget() {
        let base = block(1, 100)
        let target = block(2, 120)
        let delta = PagePack.xor(target, base: base)
        #expect(PagePack.xor(delta, base: base) == target, "longer target: base zero-padded")
        let shorter = block(3, 50)
        #expect(PagePack.xor(PagePack.xor(shorter, base: base), base: base) == shorter, "shorter target: base cut")
    }

    @Test func rejectsMalformedParts() throws {
        var writer = PagePack.Writer(blockSize: 1024, targetSize: 4096, xor: false)
        _ = writer.append(index: 1, payload: block(1, 1024))
        let flushed = writer.flush()
        let good = try #require(flushed)
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(good.prefix(20), expectedBlockSize: 1024, expectedTargetSize: 4096) }
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(good, expectedBlockSize: 2048, expectedTargetSize: 4096) }
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(good, expectedBlockSize: 1024, expectedTargetSize: 8192) }
        var badMagic = good
        badMagic[0] = 0
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(badMagic, expectedBlockSize: 1024, expectedTargetSize: 4096) }
        var truncated = good
        truncated.removeLast(8)
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(truncated, expectedBlockSize: 1024, expectedTargetSize: 4096) }
        // A header announcing more than the per-part limit is refused before decoding.
        var huge = good
        for (i, byte) in withUnsafeBytes(of: UInt64(PagePack.maximumPartRawBytes + 1).littleEndian, Array.init).enumerated() {
            huge[24 + i] = byte
        }
        #expect(throws: PagePack.DecodeError.self) { try PagePack.decodePart(huge, expectedBlockSize: 1024, expectedTargetSize: 4096) }
    }

    @Test func rejectsEntriesOutsideTargetOrOutOfOrder() throws {
        // Hand-built stored bodies.
        func part(_ body: [(UInt32, Int)], target: Int64) -> Data {
            var raw = Data()
            for (index, length) in body {
                PagePack.appendLE(&raw, index)
                raw.append(Data(repeating: 7, count: length))
            }
            var out = Data(PagePack.magic)
            out.append(contentsOf: [PagePack.version, 0b10, 0, 0])
            PagePack.appendLE(&out, UInt32(1024))
            PagePack.appendLE(&out, UInt32(body.count))
            PagePack.appendLE(&out, UInt64(target))
            PagePack.appendLE(&out, UInt64(raw.count))
            return out + raw
        }
        let outOfOrder = try PagePack.decodePart(part([(2, 1024), (1, 1024)], target: 4096), expectedBlockSize: 1024, expectedTargetSize: 4096)
        #expect(throws: PagePack.DecodeError.self) { try outOfOrder.forEachEntry { _, _ in } }
        let outside = try PagePack.decodePart(part([(9, 1024)], target: 4096), expectedBlockSize: 1024, expectedTargetSize: 4096)
        #expect(throws: PagePack.DecodeError.self) { try outside.forEachEntry { _, _ in } }
    }

    @Test func sqlitePageSizeFromHeader() {
        var header = Data("SQLite format 3\0".utf8)
        header.append(contentsOf: [0x20, 0x00])
        #expect(PagePack.sqlitePageSize(header: header) == 8192)
        header[16] = 0; header[17] = 1
        #expect(PagePack.sqlitePageSize(header: header) == 65536)
        #expect(PagePack.sqlitePageSize(header: Data("not a database at all".utf8)) == nil)
    }

    // MARK: Manifest

    func manifest(packs: ArtifactManifest.PackIndex?) -> ArtifactManifest {
        ArtifactManifest(
            generation: 5, createdAt: "2026-09-27T00:00:00Z",
            database: .init(path: ArtifactManifest.databasePath(generation: 5), byteSize: 1 << 20, sha256: String(repeating: "a", count: 64)),
            noteCount: 1, assetCount: 0, assets: .init(totalBytes: 0), builder: "test",
            chunks: .init(path: ArtifactManifest.chunkListPath(generation: 5), byteSize: 100, sha256: String(repeating: "b", count: 64), chunkSize: 131072, count: 8),
            packs: packs)
    }

    func part(_ c: Character) -> ArtifactManifest.PackIndex.Part {
        let sha = String(repeating: c, count: 64)
        return .init(path: PagePack.relativePath(for: sha)!, byteSize: 1000, sha256: sha)
    }

    @Test func manifestPackValidation() throws {
        let delta = ArtifactManifest.PackIndex.Delta(baseSHA256: String(repeating: "c", count: 64), baseByteSize: 1 << 20, blockCount: 3, parts: [part("d")])
        let keyframe = ArtifactManifest.PackIndex.Keyframe(generation: 3, byteSize: 1 << 20, sha256: String(repeating: "e", count: 64), parts: [part("f")])
        try manifest(packs: .init(blockSize: 8192, keyframe: keyframe, deltas: [delta])).validate()

        func invalid(_ packs: ArtifactManifest.PackIndex) {
            #expect(throws: ArtifactManifest.ValidationError.invalidPacks) { try manifest(packs: packs).validate() }
        }
        invalid(.init(blockSize: 3000, keyframe: nil, deltas: [delta]))
        invalid(.init(blockSize: 65536 * 4, keyframe: nil, deltas: [delta]))
        var badPath = delta
        badPath.parts[0].path = "chunks/dd/" + String(repeating: "d", count: 64)
        invalid(.init(blockSize: 8192, keyframe: nil, deltas: [badPath]))
        var selfBase = delta
        selfBase.baseSHA256 = String(repeating: "a", count: 64)
        invalid(.init(blockSize: 8192, keyframe: nil, deltas: [selfBase]))
        var future = keyframe
        future.generation = 6
        invalid(.init(blockSize: 8192, keyframe: future, deltas: []))
        var current = keyframe
        current.generation = 5
        invalid(.init(blockSize: 8192, keyframe: current, deltas: []))
        var empty = delta
        empty.parts = []
        invalid(.init(blockSize: 8192, keyframe: nil, deltas: [empty]))
    }

    @Test func readerDropsAnInvalidPackIndex() throws {
        var tooMany = ArtifactManifest.PackIndex.Delta(baseSHA256: String(repeating: "c", count: 64), baseByteSize: 1 << 20, blockCount: 1, parts: [part("d")])
        tooMany.blockCount = 1
        let packs = ArtifactManifest.PackIndex(blockSize: 8192, keyframe: nil, deltas: Array(repeating: tooMany, count: ArtifactManifest.PackIndex.maximumDeltas + 1))
        let m = manifest(packs: packs)
        #expect(throws: ArtifactManifest.ValidationError.invalidPacks) { try m.validate() }
        let usable = m.withoutInvalidPacks()
        #expect(usable.packs == nil)
        try usable.validate()
        let valid = manifest(packs: .init(blockSize: 8192, keyframe: nil, deltas: [tooMany]))
        #expect(valid.withoutInvalidPacks() == valid)
    }

    @Test func manifestWithoutPacksStillDecodes() throws {
        let data = try manifest(packs: nil).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("packs"))
        #expect(try ArtifactManifest.decode(data).packs == nil)
    }
}
