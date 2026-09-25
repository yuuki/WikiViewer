import Foundation
import Testing
@testable import WikiShared

@Suite struct ManifestTests {
    func valid() -> ArtifactManifest {
        ArtifactManifest(
            generation: 42,
            createdAt: "2026-09-25T00:00:00Z",
            database: .init(path: "generations/viewer-000042.sqlite", byteSize: 4096, sha256: String(repeating: "a", count: 64)),
            noteCount: 1,
            assetCount: 0,
            assets: .init(totalBytes: 0),
            builder: "test"
        )
    }

    @Test func roundTrip() throws {
        let m = valid()
        try m.validate()
        #expect(try ArtifactManifest.decode(m.encoded()) == m)
    }

    @Test func rejectsTraversalAndMismatchedPath() {
        var m = valid()
        m.database.path = "../../etc/passwd"
        #expect(throws: ArtifactManifest.ValidationError.invalidDatabasePath("../../etc/passwd")) { try m.validate() }
        m.database.path = "generations/viewer-000041.sqlite"
        #expect(throws: ArtifactManifest.ValidationError.self) { try m.validate() }
    }

    @Test func rejectsUnsupportedVersions() {
        var m = valid()
        m.schemaVersion = 99
        #expect(throws: ArtifactManifest.ValidationError.unsupportedSchema(99)) { try m.validate() }
        m = valid()
        m.formatVersion = 0
        #expect(throws: ArtifactManifest.ValidationError.unsupportedFormat(0)) { try m.validate() }
    }

    @Test func rejectsBadDigestAndSize() {
        var m = valid()
        m.database.sha256 = "XYZ"
        #expect(throws: ArtifactManifest.ValidationError.self) { try m.validate() }
        m = valid()
        m.database.sha256 = String(repeating: "A", count: 64)
        #expect(throws: ArtifactManifest.ValidationError.self) { try m.validate() }
        m = valid()
        m.database.byteSize = 0
        #expect(throws: ArtifactManifest.ValidationError.self) { try m.validate() }
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) { try ArtifactManifest.decode(Data("{\"formatVersion\":1}".utf8)) }
        #expect(throws: (any Error).self) { try ArtifactManifest.decode(Data(repeating: 0x20, count: 100_000)) }
    }

    @Test func assetPaths() {
        let sha = String(repeating: "b", count: 64)
        #expect(AssetBlobPath.relativePath(sha256: sha, fileExtension: "jpg") == "assets/bb/\(sha).jpg")
        #expect(AssetBlobPath.relativePath(sha256: sha, fileExtension: "../x") == nil)
        #expect(AssetBlobPath.relativePath(sha256: "../../", fileExtension: "jpg") == nil)
    }

    @Test func digestOfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (hex, count) = try Digest.sha256Hex(fileAt: url, chunkSize: 2)
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(count == 3)
    }
}

@Suite struct ChunkListTests {
    @Test func roundTripAndLengths() throws {
        let digests = (0..<3).map { String(repeating: String($0), count: 64) }
        let list = ChunkList(chunkSize: 16384, totalBytes: 16384 * 2 + 10, digests: digests)
        let decoded = try ChunkList.decode(list.encoded(), expectedTotalBytes: 16384 * 2 + 10)
        #expect(decoded == list)
        #expect(decoded.length(of: 0) == 16384)
        #expect(decoded.length(of: 2) == 10)
    }

    @Test func rejectsInconsistentLists() {
        let d = String(repeating: "a", count: 64)
        let ok = ChunkList(chunkSize: 16384, totalBytes: 100, digests: [d]).encoded()
        #expect(throws: ChunkList.DecodeError.self) { try ChunkList.decode(ok, expectedTotalBytes: 101) }
        let tooMany = ChunkList(chunkSize: 16384, totalBytes: 100, digests: [d, d]).encoded()
        #expect(throws: ChunkList.DecodeError.self) { try ChunkList.decode(tooMany, expectedTotalBytes: 100) }
        let badSize = ChunkList(chunkSize: 7, totalBytes: 7, digests: [d]).encoded()
        #expect(throws: ChunkList.DecodeError.self) { try ChunkList.decode(badSize, expectedTotalBytes: 7) }
        let badDigest = Data("wikiviewer-chunks 1 16384 1 100\n../../etc/passwd\n".utf8)
        #expect(throws: ChunkList.DecodeError.self) { try ChunkList.decode(badDigest, expectedTotalBytes: 100) }
        #expect(throws: ChunkList.DecodeError.self) { try ChunkList.decode(Data("garbage".utf8), expectedTotalBytes: 100) }
        #expect(ChunkList.relativePath(for: "../x") == nil)
    }

    @Test func makeMatchesWholeFileDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data((0..<50_000).map { UInt8($0 % 251) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (list, sha) = try ChunkList.make(fileAt: url, chunkSize: 16384)
        #expect(sha == Digest.sha256Hex(data))
        #expect(list.digests.count == 4)
        #expect(list.digests[3] == Digest.sha256Hex(data.suffix(50_000 - 3 * 16384)))
    }

    @Test func manifestChunkEntryValidation() throws {
        var m = ArtifactManifest(
            generation: 3, createdAt: "x",
            database: .init(path: "generations/viewer-000003.sqlite", byteSize: 300_000, sha256: String(repeating: "a", count: 64)),
            noteCount: 1, assetCount: 0, assets: .init(totalBytes: 0), builder: "t",
            chunks: .init(path: "generations/viewer-000003.chunks", byteSize: 500, sha256: String(repeating: "b", count: 64), chunkSize: 131072, count: 3)
        )
        try m.validate()
        m.chunks?.count = 2
        #expect(throws: ArtifactManifest.ValidationError.invalidChunkList) { try m.validate() }
        m.chunks?.count = 3
        m.chunks?.path = "../chunks"
        #expect(throws: ArtifactManifest.ValidationError.invalidChunkList) { try m.validate() }
    }
}
