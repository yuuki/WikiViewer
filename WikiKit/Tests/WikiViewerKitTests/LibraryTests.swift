import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

@MainActor
@Suite struct LibraryTests {
    let tmp = TempDir()

    func makeLibrary() throws -> Library {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return Library(store: try GenerationStore(root: tmp.sub("WikiViewer")), defaults: defaults)
    }

    @Test func firstLaunchInstallsBundledDemo() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let session = try #require(library.session)
        #expect(session.info.generation == 1)
        #expect(library.source == .bundledDemo)
        #expect(await library.store.currentGeneration() != nil)
    }

    @Test func updateSwitchesGenerationAndKeepsFallback() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let first = try #require(library.session)
        let dir = tmp.sub("pub")
        try makeArtifact(at: dir, generation: 5) { db in
            try db.execute(sql: "UPDATE notes SET title = 'Home v5' WHERE path = 'Home.md'")
        }
        let bookmark = try dir.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions)
        library.setSource(.folder(bookmark: bookmark, displayName: "pub"))
        await library.checkForUpdates()
        #expect(library.updateStatus.isUpdated)
        let second = try #require(library.session)
        #expect(second.info.generation == 5)
        #expect(second.id != first.id)
        let homeID = try #require(try await second.notes.noteID(path: "Home.md"))
        #expect(try await second.notes.summary(id: homeID)?.title == "Home v5")
        // The old session keeps working until released (its files are the fallback).
        #expect(try await first.notes.noteID(path: "Home.md") != nil)
        #expect(await library.store.previousGeneration() == first.installed)
    }

    @Test func corruptCurrentFallsBackToPrevious() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let first = try #require(library.session?.installed)
        let dir = tmp.sub("pub")
        try makeArtifact(at: dir, generation: 2)
        library.setSource(.folder(bookmark: try dir.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions), displayName: "pub"))
        await library.checkForUpdates()
        let second = try #require(library.session?.installed)
        #expect(second.generation == 2)

        // Simulate on-disk damage of the current generation, then relaunch.
        let url = library.store.databaseURL(for: second)
        try Data("garbage".utf8).write(to: url)
        let relaunched = Library(store: library.store, defaults: UserDefaults(suiteName: "x-\(UUID().uuidString)")!)
        await relaunched.bootstrap()
        #expect(relaunched.session?.installed == first, "fell back to the previous generation")
        #expect(await relaunched.store.currentGeneration() == first)
        #expect(await relaunched.store.previousGeneration() != second, "the broken generation never becomes the fallback")
        #expect(!(await relaunched.store.installedGenerations().contains(second)), "broken generation removed")
    }

    @Test func failedUpdateKeepsCurrentSession() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let before = try #require(library.session)
        let dir = tmp.sub("bad")
        try makeArtifact(at: dir, generation: 9, editManifest: { $0.database.sha256 = String(repeating: "f", count: 64) })
        library.setSource(.folder(bookmark: try dir.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions), displayName: "bad"))
        await library.checkForUpdates()
        guard case .failed = library.updateStatus else { Issue.record("expected failure, got \(library.updateStatus)"); return }
        #expect(library.session?.id == before.id)
    }

    @Test func assetsAreFetchedLazilyAndVerified() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let session = try #require(library.session)
        let homeID = try #require(try await session.notes.noteID(path: "Home.md"))
        let links = try await session.links.outgoingLinks(of: homeID)
        let photoID = try #require(links.first { $0.raw == "photo.jpg|400" }?.targetAssetID)
        let photo = try #require(try await session.assets.asset(id: photoID))
        let local = try #require(library.assetProvider.localURL(sha256: photo.blobSHA256!, ext: photo.blobExt!))
        #expect(!FileManager.default.fileExists(atPath: local.path), "nothing fetched eagerly")
        let url = try await library.blobURL(for: photo)
        #expect(url == local)
        let image = try #require(ImageDownsampler.downsample(at: url, maxPixelSize: 400))
        #expect(max(image.width, image.height) == 400)
        #expect(image.height > image.width, "EXIF orientation applied (portrait)")

        // A tampered blob is rejected.
        var tampered = photo
        tampered.blobSHA256 = String(repeating: "e", count: 64)
        let dir = tmp.sub("tamper/assets/ee")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not the image".utf8).write(to: dir.appendingPathComponent("\(tampered.blobSHA256!).jpg"))
        let provider = AssetProvider(storeRoot: tmp.sub("other/assets"), source: LocalFolderArtifactSource(root: tmp.sub("tamper")))
        await #expect(throws: AssetProvider.AssetError.hashMismatch) { _ = try await provider.blobURL(for: tampered) }
    }

    @Test func switchingSourceChecksTheNewSource() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        let dir = tmp.sub("pub7")
        try makeArtifact(at: dir, generation: 7)
        library.setSource(.folder(bookmark: try dir.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions), displayName: "pub7"))
        async let first: Void = library.checkForUpdates()
        library.setSource(.folder(bookmark: try dir.bookmarkData(options: SourceConfiguration.bookmarkCreationOptions), displayName: "pub7"))
        async let second: Void = library.checkForUpdates()
        _ = await (first, second)
        #expect(library.session?.info.generation == 7)
    }

    @Test func resetWhileIdleLeavesEmptyLibrary() async throws {
        let library = try makeLibrary()
        await library.bootstrap()
        await library.resetLocalData()
        #expect(library.session == nil)
        #expect(await library.store.installedGenerations().isEmpty)
    }

    @Test func imageCacheIsBounded() throws {
        let cache = ImageCache(limitBytes: 1_000_000)
        let url = demoArtifact.appendingPathComponent("assets")
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "jpg" }
        let file = try #require(files.first)
        let image = try #require(ImageDownsampler.downsample(at: file, maxPixelSize: 300))
        for i in 0..<50 {
            cache.insert(image, for: .init(sha256: "\(i)", maxPixelSize: 300))
        }
        #expect(cache.totalBytes <= 1_000_000)
        #expect(cache.image(for: .init(sha256: "49", maxPixelSize: 300)) != nil)
        #expect(cache.image(for: .init(sha256: "0", maxPixelSize: 300)) == nil)
    }
}

extension Library.UpdateStatus {
    var isUpdated: Bool { if case .updated = self { true } else { false } }
}
