//
//  RequestQueue.swift
//  WikiViewerKit
//
//  Requests to the Mac (HostRequest) waiting on this device. A request is
//  kept here from the moment it is made: offline, it waits until the source
//  can be reached; once sent, the queue follows its status file until the
//  Mac reports it done or failed. Saved as one small JSON file next to the
//  snapshots (it survives "Delete Local Snapshots").
//

import Foundation
import Observation
import WikiShared

@MainActor
@Observable
public final class RequestQueue {
    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var request: HostRequest
        /// When the Mac's queue accepted it; nil while waiting to be sent.
        public var sentAt: Date?
        /// The last status file read from the Mac.
        public var status: HostRequestStatus?
        /// Why the last attempt to send failed (shown, retried later).
        public var lastError: String?

        public var id: UUID { request.id }

        public enum Phase: Equatable, Sendable {
            /// Not yet in the Mac's queue (offline, or the send failed).
            case waiting
            /// In the Mac's queue, not started.
            case queued
            case processing
            case done
            case failed
        }

        public var phase: Phase {
            guard sentAt != nil else { return .waiting }
            switch status?.state {
            case nil, .queued: return .queued
            case .processing: return .processing
            case .done: return .done
            case .failed: return .failed
            }
        }

        /// Still needs the network: not sent, or sent and not finished.
        var isActive: Bool { sentAt == nil || !(status?.state.isFinal ?? false) }
    }

    /// Newest first.
    public private(set) var entries: [Entry] = []
    /// True while `sync` runs.
    public private(set) var isSyncing = false

    /// Requests kept on the device (finished ones are dropped oldest first).
    static let maximumEntries = 200
    /// A sent request whose status never appears is given up after this.
    static let statusTimeout: TimeInterval = 14 * 24 * 3600
    static let awaitingHostWindow: TimeInterval = 30 * 60

    private let fileURL: URL?

    /// `fileURL` nil keeps the queue in memory (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? HostRequest.decoder.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Requests the reader sees (reading signals are sent quietly).
    public var visibleEntries: [Entry] { entries.filter { $0.request.kind != .signals } }

    /// Visible requests still waiting for an answer.
    public var pendingCount: Int { visibleEntries.filter(\.isActive).count }
    /// Whether a request sent within `awaitingHostWindow` still waits for
    /// the Mac's answer, which is then expected soon.
    func isAwaitingHost(now: Date = Date()) -> Bool {
        entries.contains { entry in
            guard entry.isActive, let sentAt = entry.sentAt else { return false }
            return now.timeIntervalSince(sentAt) < Self.awaitingHostWindow
        }
    }

    public func entry(id: UUID) -> Entry? { entries.first { $0.id == id } }

    /// Validates and queues a request. Call `sync` to send it.
    public func enqueue(_ request: HostRequest) throws {
        try request.validate()
        _ = try request.encoded()
        entries.insert(Entry(request: request), at: 0)
        trim()
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Removes every finished request.
    public func removeFinished() {
        entries.removeAll { !$0.isActive && $0.request.kind != .signals }
        save()
    }

    /// Sends what is waiting and reads the status of what is in progress.
    /// Failures are recorded on the entries and retried on the next call.
    public func sync(source: (any ArtifactSource)?, now: Date = Date()) async {
        guard let source, source.acceptsRequests, !isSyncing, entries.contains(where: \.isActive) else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Oldest first, so requests reach the Mac in the order they were made.
        for id in entries.reversed().filter(\.isActive).map(\.id) {
            guard !Task.isCancelled, let entry = entry(id: id) else { return }
            if entry.sentAt == nil {
                do {
                    try await source.submitRequest(try entry.request.encoded(), id: id)
                    update(id) {
                        $0.sentAt = now
                        $0.lastError = nil
                    }
                } catch is CancellationError {
                    return
                } catch {
                    update(id) { $0.lastError = String(describing: error) }
                    // Offline or refused: the later ones would fail the same way.
                    break
                }
            } else {
                do {
                    let status = try await source.fetchRequestStatus(id: id)
                    if status.id == id { update(id) { $0.status = status } }
                } catch is CancellationError {
                    return
                } catch {
                    // Not picked up yet (no status file), or unreachable.
                    if let sentAt = entry.sentAt, now.timeIntervalSince(sentAt) > Self.statusTimeout {
                        update(id) {
                            $0.status = HostRequestStatus(id: id, kind: $0.request.kind, state: .failed, updatedAt: now,
                                                          message: "The Mac did not answer.")
                        }
                    }
                }
            }
        }
        trim()
        save()
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// Drops the oldest finished requests beyond the limit.
    private func trim() {
        while entries.count > Self.maximumEntries, let last = entries.lastIndex(where: { !$0.isActive }) {
            entries.remove(at: last)
        }
    }

    private func save() {
        guard let fileURL else { return }
        if let data = try? HostRequest.encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
