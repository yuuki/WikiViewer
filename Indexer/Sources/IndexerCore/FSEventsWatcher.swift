//
//  FSEventsWatcher.swift
//  IndexerCore
//
//  One FSEvents stream for the whole vault (never one watcher per file).
//  The watcher is only a fast path: dropped or coalesced events are
//  reported as `.rescan`, and periodic reconciliation covers anything else.
//

import CoreServices
import Foundation
import Synchronization
import WikiShared

public enum WatchEvent: Sendable, Equatable {
    /// Vault-relative paths that may have changed (files or directories).
    case paths([String])
    /// Events were dropped or must be rescanned: reconcile this subtree
    /// (nil = the whole vault).
    case rescan(String?)
}

public final class FSEventsWatcher: Sendable {
    public let root: URL
    let latency: CFTimeInterval

    public init(root: URL, latency: CFTimeInterval = 0.3) {
        self.root = root
        self.latency = latency
    }

    /// Starts the stream. It stops when the returned sequence is no longer
    /// iterated (task cancelled / stream deinitialized).
    public func events() -> AsyncStream<WatchEvent> {
        let (stream, continuation) = AsyncStream<WatchEvent>.makeStream(bufferingPolicy: .unbounded)
        let context = CallbackContext(rootPath: root.canonicalPath, continuation: continuation)
        let queue = DispatchQueue(label: "wikiindex.fsevents")

        var fsContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(context).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &fsContext,
            [context.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Log.error("FSEventStreamCreate failed; relying on periodic reconciliation")
            continuation.finish()
            return stream
        }
        FSEventStreamSetDispatchQueue(ref, queue)
        if !FSEventStreamStart(ref) {
            Log.error("FSEventStreamStart failed; relying on periodic reconciliation")
        }
        // Ownership moves into the handle; `ref` is not used after this point.
        let handle = StreamHandle(ref)
        continuation.onTermination = { _ in
            queue.async {
                handle.stream.withLock { ref in
                    guard let r = ref else { return }
                    FSEventStreamStop(r)
                    FSEventStreamInvalidate(r)
                    FSEventStreamRelease(r)
                    ref = nil
                }
            }
        }
        return stream
    }
}

/// Owns the stream reference; all mutation goes through the mutex.
private final class StreamHandle: Sendable {
    let stream: Mutex<FSEventStreamRef?>

    init(_ ref: sending FSEventStreamRef) {
        stream = Mutex(ref)
    }
}

private final class CallbackContext: Sendable {
    let rootPath: String
    let continuation: AsyncStream<WatchEvent>.Continuation

    init(rootPath: String, continuation: AsyncStream<WatchEvent>.Continuation) {
        self.rootPath = rootPath
        self.continuation = continuation
    }

    func relative(_ absolute: String) -> String? {
        if absolute == rootPath { return "" }
        let prefix = rootPath + "/"
        guard absolute.hasPrefix(prefix) else { return nil }
        return String(absolute.dropFirst(prefix.count))
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
    guard let info else { return }
    let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
    let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    var changed: [String] = []
    for i in 0..<count {
        let flags = Int(rawFlags[i])
        let absolute = String(cString: paths[i])
        if flags & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
            context.continuation.yield(.rescan(nil))
            continue
        }
        guard let relative = context.relative(absolute) else { continue }
        if flags & kFSEventStreamEventFlagMustScanSubDirs != 0 {
            context.continuation.yield(.rescan(relative.isEmpty ? nil : VaultPath.normalizeRelative(relative)))
            continue
        }
        if let normalized = VaultPath.normalizeRelative(relative) {
            changed.append(normalized)
        }
    }
    if !changed.isEmpty {
        context.continuation.yield(.paths(changed))
    }
}
