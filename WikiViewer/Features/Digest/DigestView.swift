//
//  DigestView.swift
//  WikiViewer
//
//  The morning paper (#36): what Claude (and the reader) did to the vault
//  since the app was last open. The host records per generation what
//  changed and the vault's log entries; the device only remembers which
//  generation it last showed and reads what came after.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// Which generation "since you last looked" starts after. Per device, in
/// UserDefaults: the generation open when the app last went to the
/// background becomes the baseline the next time it comes back.
@MainActor
@Observable
final class DigestState {
    enum Range: String, CaseIterable, Identifiable {
        case lastVisit, day, week
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .lastVisit: "Since Last Visit"
            case .day: "Last 24 Hours"
            case .week: "Last 7 Days"
            }
        }
    }

    static let seenKey = "WikiViewer.digest.seenGeneration"
    static let leftKey = "WikiViewer.digest.leftAt"
    static let baselineKey = "WikiViewer.digest.baseline"
    /// A shorter absence (switching apps or windows) is the same visit.
    static let newVisitAfter: TimeInterval = 30 * 60

    var range: Range = .lastVisit
    /// The generation the digest starts after, for `lastVisit`.
    private(set) var baseline: Int64?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseline = (defaults.object(forKey: Self.baselineKey) as? NSNumber)?.int64Value
    }

    /// The app left the foreground showing `generation`.
    func leave(showing generation: Int64?) {
        guard let generation else { return }
        defaults.set(NSNumber(value: generation), forKey: Self.seenKey)
        defaults.set(Date.now, forKey: Self.leftKey)
    }

    /// The app came back: what was showing when it left is the new baseline.
    func arrive(now: Date = .now) {
        if let left = defaults.object(forKey: Self.leftKey) as? Date, now.timeIntervalSince(left) < Self.newVisitAfter { return }
        guard let seen = (defaults.object(forKey: Self.seenKey) as? NSNumber)?.int64Value, seen != baseline else { return }
        baseline = seen
        defaults.set(NSNumber(value: seen), forKey: Self.baselineKey)
    }

    /// Everything up to `generation` is read.
    func markRead(upTo generation: Int64) {
        baseline = generation
        defaults.set(NSNumber(value: generation), forKey: Self.baselineKey)
        defaults.set(NSNumber(value: generation), forKey: Self.seenKey)
    }

    /// The generation the digest starts after.
    func start(in session: LibrarySession, now: Date = .now) async -> Int64 {
        switch range {
        case .lastVisit:
            if let baseline { return min(baseline, session.info.generation) }
            // Never opened before: the last day.
            return (try? await session.changes.generation(before: now.addingTimeInterval(-24 * 3600))) ?? 0
        case .day:
            return (try? await session.changes.generation(before: now.addingTimeInterval(-24 * 3600))) ?? 0
        case .week:
            return (try? await session.changes.generation(before: now.addingTimeInterval(-7 * 24 * 3600))) ?? 0
        }
    }
}

/// Loads the digest for the current range and session.
@MainActor
@Observable
final class DigestModel {
    private(set) var digest: ChangeDigest?

    func load(session: LibrarySession, state: DigestState) async {
        let start = await state.start(in: session)
        digest = try? await session.changes.digest(after: start)
    }
}

/// The row on the home list: a one-line summary that opens the digest.
struct DigestHomeSection: View {
    let digest: ChangeDigest?
    @Environment(DigestState.self) private var state

    var body: some View {
        if let digest, !digest.isEmpty {
            Section {
                RouteLink(Route.digest) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.range == .lastVisit && state.baseline != nil ? "Since Your Last Visit" : "Recent Changes")
                            Text(DigestSummary.line(digest))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "newspaper")
                    }
                }
            }
            .listRowSection("digest")
        }
    }

    struct TaskKey: Equatable {
        var session: String?
        var baseline: Int64?
        var range: DigestState.Range
    }
}

enum DigestSummary {
    /// "3 sources ingested · 5 concepts · 1 verdict · 2 of your notes".
    static func line(_ digest: ChangeDigest) -> String {
        var parts: [String] = []
        let ingested = max(digest.ingests.count, digest.sources.count)
        if ingested > 0 { parts.append(String(localized: "Sources ingested: \(ingested)")) }
        if !digest.concepts.isEmpty { parts.append(String(localized: "Concepts: \(digest.concepts.count)")) }
        if !digest.theses.isEmpty { parts.append(String(localized: "Verdicts: \(digest.theses.count)")) }
        if !digest.otherClaudeChanges.isEmpty { parts.append(String(localized: "Other wiki pages: \(digest.otherClaudeChanges.count)")) }
        if !digest.humanChanges.isEmpty { parts.append(String(localized: "Your notes: \(digest.humanChanges.count)")) }
        return parts.joined(separator: " · ")
    }
}

/// The digest: ingested sources, concepts rewritten, theses judged, other
/// wiki pages and the reader's own edits, each opening its note.
struct DigestView: View {
    @Environment(Library.self) private var library
    @Environment(DigestState.self) private var state
    @State private var model = DigestModel()

    var body: some View {
        @Bindable var state = state
        RouteList {
            Section {
                Picker("Range", selection: $state.range) {
                    ForEach(DigestState.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let digest = model.digest {
                content(digest)
            }
        }
        .overlay {
            if let digest = model.digest, digest.isEmpty {
                ContentUnavailableView("Nothing New", systemImage: "newspaper",
                                       description: Text("Nothing changed in the vault in this period."))
            }
        }
        .navigationTitle("What Changed")
        .toolbar {
            if let generation = library.session?.info.generation, model.digest?.isEmpty == false {
                Button("Mark as Read", systemImage: "checkmark") {
                    state.markRead(upTo: generation)
                    state.range = .lastVisit
                }
            }
        }
        .task(id: DigestHomeSection.TaskKey(session: library.session?.id, baseline: state.baseline, range: state.range)) {
            guard let session = library.session else { return }
            await model.load(session: session, state: state)
        }
    }

    @ViewBuilder
    private func content(_ digest: ChangeDigest) -> some View {
        if !digest.ingests.isEmpty {
            Section("Ingested") {
                ForEach(digest.ingests, id: \.[row: "ingests"]) { entry in
                    LogEntryRow(entry: entry)
                }
            }
            .listRowSection("ingests")
        } else if !digest.sources.isEmpty {
            changeSection("New Sources", digest.sources, digest: digest, id: "sources")
        }
        changeSection("Concepts", digest.concepts, digest: digest, id: "concepts")
        changeSection("Verdicts", digest.theses, digest: digest, id: "theses")
        let others = digest.entries.filter { !$0.isIngest }
        if !others.isEmpty {
            Section("Other Log Entries") {
                ForEach(others, id: \.[row: "entries"]) { LogEntryRow(entry: $0) }
            }
            .listRowSection("entries")
        }
        changeSection("Other Wiki Pages", digest.otherClaudeChanges, digest: digest, id: "wiki")
        changeSection("Your Notes", digest.humanChanges, digest: digest, id: "human")
        if digest.truncated {
            Section {
                Text("Only the most recent changes are listed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func changeSection(_ title: LocalizedStringKey, _ changes: [NoteChange], digest: ChangeDigest, id: String) -> some View {
        if !changes.isEmpty {
            Section(title) {
                ForEach(changes, id: \.[row: id]) { change in
                    ChangeRow(change: change, reason: digest.reason(for: change.path))
                }
            }
            .listRowSection(id)
        }
    }
}

struct ChangeRow: View {
    let change: NoteChange
    let reason: LogEntry?

    var body: some View {
        if change.kind == .removed {
            label.foregroundStyle(.secondary)
        } else {
            RouteLink(Route.note(path: change.path, anchor: nil)) { label }
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(kindTitle)
                    if let reason {
                        Text("· \(reason.operation): \(reason.title)").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: change.kind == .added ? "plus.circle" : change.kind == .removed ? "minus.circle" : "pencil.circle")
        }
    }

    private var kindTitle: LocalizedStringKey {
        switch change.kind {
        case .added: "New"
        case .modified: "Updated"
        case .removed: "Removed"
        }
    }
}

/// An entry of the vault's operation log: what was done, and the pages.
struct LogEntryRow: View {
    let entry: LogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(entry.date).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.operation).font(.caption).foregroundStyle(.secondary)
            if let insight = Self.field("Key insight", in: entry.body) ?? Self.field("Summary", in: entry.body) {
                Text(LearningPath.readable(insight))
                    .font(.footnote)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { expanded.toggle() }
            }
            if !entry.pages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entry.pages.prefix(12), id: \.path) { page in
                            RouteLink(Route.note(path: page.path, anchor: nil)) {
                                Text(page.label)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.tint.opacity(0.12), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The value of a "- Key: value" line of a log entry.
    static func field(_ key: String, in body: String) -> String? {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- \(key):") else { continue }
            return trimmed.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
