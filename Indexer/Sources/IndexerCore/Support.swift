//
//  Support.swift
//  IndexerCore
//

import Foundation
import Synchronization

/// Minimal stderr logger. The indexer is a CLI/daemon; structured logging
/// can be layered on later without touching call sites.
public enum Log {
    public enum Level: Int, Sendable, Comparable {
        case debug, info, warning, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    private static let minimum = Atomic<Int>(Level.info.rawValue)

    public static func setLevel(_ level: Level) {
        minimum.store(level.rawValue, ordering: .relaxed)
    }

    public static func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
    public static func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public static func warning(_ message: @autoclosure () -> String) { write(.warning, message) }
    public static func error(_ message: @autoclosure () -> String) { write(.error, message) }

    private static func write(_ level: Level, _ message: () -> String) {
        guard level.rawValue >= minimum.load(ordering: .relaxed) else { return }
        let prefix = switch level {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
        let line = "[\(prefix)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

public enum IndexerError: Error, CustomStringConvertible {
    case unsafeLocation(String)
    case notADirectory(String)
    case publicationFailed(String)
    case integrityCheckFailed(String)
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .unsafeLocation(let s): "Unsafe location: \(s)"
        case .notADirectory(let s): "Not a directory: \(s)"
        case .publicationFailed(let s): "Publication failed: \(s)"
        case .integrityCheckFailed(let s): "Integrity check failed: \(s)"
        case .invalidConfiguration(let s): "Invalid configuration: \(s)"
        }
    }
}

/// Monotonic clock helpers for benchmarks and scheduling.
public enum Clock {
    public static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    public static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Peak resident set size of this process in bytes (macOS reports bytes).
public func peakResidentBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

/// fsync a file or directory by path. Errors are reported, not ignored.
func fsyncPath(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    // F_FULLFSYNC asks the drive to flush its cache on macOS; fall back to fsync.
    if fcntl(fd, F_FULLFSYNC) != 0 {
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Atomically replaces `destination` with `source` (same volume) via rename(2).
func atomicRename(_ source: URL, to destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

extension URL {
    /// Absolute path with symlinks resolved by realpath(3), without a
    /// trailing slash. (Foundation's resolvingSymlinksInPath() strips
    /// "/private" from "/private/var/…", which would not match the real paths
    /// that FSEvents reports.)
    /// Paths that do not exist yet are resolved through their longest
    /// existing ancestor, so safety checks also hold for directories that are
    /// about to be created.
    var canonicalPath: String {
        var existing = self.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                var path = String(cString: resolved)
                for component in missing.reversed() {
                    path += (path.hasSuffix("/") ? "" : "/") + component
                }
                return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { return self.standardizedFileURL.path }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
    }

    /// True if `self` equals `other` or is located inside it.
    func isInside(_ other: URL) -> Bool {
        let a = canonicalPath
        let b = other.canonicalPath
        return a == b || a.hasPrefix(b + "/")
    }
}
