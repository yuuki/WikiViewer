//
//  GenerationStore.swift
//  WikiViewerKit
//
//  On-device layout (Application Support is runtime storage; transport
//  locations never are):
//
//    WikiViewer/
//      generations/000041-3f9a0c1d2e4b/viewer.sqlite + manifest.json  (previous)
//      generations/000042-ab12cd34ef56/viewer.sqlite + manifest.json  (current)
//      staging/<uuid>/                                                (in-flight)
//      assets/ab/ab12…ef.jpg                             (shared, content-addressed)
//      current     "000042-ab12cd34ef56"
//      previous    "000041-3f9a0c1d2e4b"
//      lineage     identifier of the source the current generation came from
//
//  A generation directory is named by generation number AND database digest,
//  so two sources that both publish "generation 1" never collide.
//
//  Invariants:
//  - A directory under generations/ is only created by renaming a fully
//    validated staging directory; its files are never modified afterwards.
//  - Pointers are replaced atomically (write temp + rename).
//  - Only generations other than current and previous are deleted.
//

import Foundation
import WikiShared

public struct InstalledGeneration: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var generation: Int64
    public var digestPrefix: String

    public init(generation: Int64, digestPrefix: String) {
        self.generation = generation
        self.digestPrefix = digestPrefix
    }

    init(manifest: ArtifactManifest) {
        self.init(generation: manifest.generation, digestPrefix: String(manifest.database.sha256.prefix(12)))
    }

    public var name: String { ArtifactManifest.paddedGeneration(generation) + "-" + digestPrefix }
    public var description: String { name }

    init?(name: String) {
        let parts = name.split(separator: "-")
        guard parts.count == 2, parts[0].count >= 6, parts[0].allSatisfy(\.isNumber), let gen = Int64(parts[0]),
              parts[1].count == 12, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        self.init(generation: gen, digestPrefix: String(parts[1]))
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.generation, a.digestPrefix) < (b.generation, b.digestPrefix)
    }
}

public actor GenerationStore {
    public nonisolated let root: URL
    public nonisolated var generationsURL: URL { root.appendingPathComponent("generations", isDirectory: true) }
    public nonisolated var stagingURL: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public nonisolated var assetsURL: URL { root.appendingPathComponent("assets", isDirectory: true) }

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for dir in ["", "generations", "staging", "assets"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // Derived, re-downloadable data: keep it out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    /// Default location: Application Support/WikiViewer.
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("WikiViewer", isDirectory: true)
    }

    public nonisolated func directory(for generation: InstalledGeneration) -> URL {
        generationsURL.appendingPathComponent(generation.name, isDirectory: true)
    }

    public nonisolated func databaseURL(for generation: InstalledGeneration) -> URL {
        directory(for: generation).appendingPathComponent("viewer.sqlite")
    }

    // MARK: Pointers

    func readPointer(_ name: String) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writePointer(_ name: String, _ value: String?) throws {
        let url = root.appendingPathComponent(name)
        guard let value else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let tmp = root.appendingPathComponent(".\(name).\(UUID().uuidString)")
        try Data(value.utf8).write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    public func currentGeneration() -> InstalledGeneration? {
        readPointer("current").flatMap(InstalledGeneration.init(name:))
    }

    public func previousGeneration() -> InstalledGeneration? {
        readPointer("previous").flatMap(InstalledGeneration.init(name:))
    }

    /// Identifier of the source the current generation came from.
    public func lineage() -> String? { readPointer("lineage") }

    /// Atomically makes `generation` current; the old current becomes previous.
    public func setCurrent(_ generation: InstalledGeneration, lineage: String?) throws {
        let old = currentGeneration()
        if let old, old != generation {
            try writePointer("previous", old.name)
        }
        try writePointer("current", generation.name)
        if let lineage { try writePointer("lineage", lineage) }
    }

    // MARK: Generations

    /// Generations with both files present, newest first.
    public func installedGenerations() -> [InstalledGeneration] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: generationsURL.path)) ?? []
        return names.compactMap { name -> InstalledGeneration? in
            guard let gen = InstalledGeneration(name: name) else { return nil }
            let dir = directory(for: gen)
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.appendingPathComponent("viewer.sqlite").path),
                  fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { return nil }
            return gen
        }.sorted(by: >)
    }

    public func manifest(for generation: InstalledGeneration) -> ArtifactManifest? {
        guard let data = try? Data(contentsOf: directory(for: generation).appendingPathComponent("manifest.json")) else { return nil }
        return try? ArtifactManifest.decode(data)
    }

    /// Order in which to try opening at launch: current, previous, then any
    /// other installed generation newest first.
    public func openCandidates() -> [InstalledGeneration] {
        let installed = installedGenerations()
        var order: [InstalledGeneration] = []
        for pointer in [currentGeneration(), previousGeneration()] {
            if let p = pointer, installed.contains(p), !order.contains(p) { order.append(p) }
        }
        order.append(contentsOf: installed.filter { !order.contains($0) })
        return order
    }

    /// Removes leftovers of interrupted updates (app killed mid-download).
    public func cleanStaging() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: stagingURL.path)) ?? [] {
            try? fm.removeItem(at: stagingURL.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".current.") || name.hasPrefix(".previous.") || name.hasPrefix(".lineage.") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        // Partial asset downloads interrupted by termination.
        for prefix in (try? fm.contentsOfDirectory(atPath: assetsURL.path)) ?? [] where prefix.count == 2 {
            let dir = assetsURL.appendingPathComponent(prefix)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".part") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    public func makeStagingDirectory() throws -> URL {
        let dir = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves a validated staging directory into generations/.
    public func install(stagingDirectory: URL, manifest: ArtifactManifest) throws -> InstalledGeneration {
        let generation = InstalledGeneration(manifest: manifest)
        let target = directory(for: generation)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            if self.manifest(for: generation) == manifest {
                // Same content already installed (interrupted earlier run).
                try? fm.removeItem(at: stagingDirectory)
                return generation
            }
            guard generation != currentGeneration(), generation != previousGeneration() else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: stagingDirectory, to: target)
        return generation
    }

    /// After `current` failed to open: make `good` current, keep a previous
    /// pointer only if it still names a usable generation, and delete the
    /// broken ones (so a broken generation never becomes the fallback).
    public func fallBack(to good: InstalledGeneration, discarding broken: [InstalledGeneration]) throws {
        let brokenSet = Set(broken)
        let oldPrevious = previousGeneration()
        try writePointer("current", good.name)
        if let oldPrevious, oldPrevious != good, !brokenSet.contains(oldPrevious) {
            try writePointer("previous", oldPrevious.name)
        } else {
            let other = installedGenerations().first { $0 != good && !brokenSet.contains($0) }
            try writePointer("previous", other?.name)
        }
        for generation in brokenSet where generation != good {
            try? FileManager.default.removeItem(at: directory(for: generation))
        }
    }

    /// Deletes asset blobs whose names (`<sha256>.<ext>`) are not in `keep`.
    /// Only well-formed blob names are ever deleted.
    public func collectAssets(keeping keep: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        for prefix in (try? fm.contentsOfDirectory(atPath: assetsURL.path)) ?? [] where prefix.count == 2 {
            let dir = assetsURL.appendingPathComponent(prefix)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
                guard let dot = name.firstIndex(of: "."), Digest.isValidHex(String(name[..<dot])) else { continue }
                try? fm.removeItem(at: dir.appendingPathComponent(name))
                removed += 1
            }
        }
        return removed
    }

    /// Deletes a generation that failed to open (never current/previous).
    public func discard(_ generation: InstalledGeneration) {
        guard generation != currentGeneration(), generation != previousGeneration() else { return }
        try? FileManager.default.removeItem(at: directory(for: generation))
    }

    /// Keeps current and previous; deletes every other generation directory.
    public func prune() {
        let keep = Set([currentGeneration(), previousGeneration()].compactMap { $0 })
        guard !keep.isEmpty else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: generationsURL.path)) ?? [] {
            if let gen = InstalledGeneration(name: name), keep.contains(gen) { continue }
            try? fm.removeItem(at: generationsURL.appendingPathComponent(name))
        }
    }

    /// Removes every local generation and asset (user-initiated reset).
    public func removeAll() throws {
        let fm = FileManager.default
        for url in [generationsURL, stagingURL, assetsURL] {
            try? fm.removeItem(at: url)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for pointer in ["current", "previous", "lineage"] {
            try? fm.removeItem(at: root.appendingPathComponent(pointer))
        }
    }

    /// Total allocated size, computed off the caller's actor.
    @concurrent
    public nonisolated func diskUsageInBackground() async -> Int64 {
        diskUsage()
    }

    /// Walks the store without holding the actor (can take a while with many blobs).
    public nonisolated func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
