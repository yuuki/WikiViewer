//
//  LibraryHomeSections.swift
//  WikiViewer
//
//  The top of the Files tab: today's daily note, pinned notes and recently
//  read notes, so the usual next note is one tap away in a vault too large
//  to browse by folder.
//

import SwiftUI
import WikiViewerKit

struct LibraryHomeSections: View {
    /// Today's daily note, if the vault has one (see `findTodaysNote`).
    let today: NoteSummary?
    @Environment(ReadingHistory.self) private var history
    /// The recent notes as listed. Reading a note moves it to the top of the
    /// history. On macOS, while only notes already listed are read again
    /// (going through the list with the arrow keys reads each one), the
    /// list keeps its order, so the next row stays the next note.
    @State private var recents: [HistoryEntry] = []

    static let recentLimit = 5

    /// The rows to show. Until `recents` is first filled, the history: with
    /// no rows yet, the Group below is empty and its onChange never runs.
    private var listedRecents: [HistoryEntry] {
        recents.isEmpty ? Array(history.recents.prefix(Self.recentLimit)) : recents
    }

    var body: some View {
        Group { sections }
            .onChange(of: history.recents, initial: true) {
                let latest = Array(history.recents.prefix(Self.recentLimit))
                #if os(macOS)
                if Set(latest.map(\.path)) != Set(recents.map(\.path)) { recents = latest }
                #else
                recents = latest
                #endif
            }
    }

    @ViewBuilder
    private var sections: some View {
        if let today {
            Section {
                RouteLink(Route.note(path: today.path, anchor: nil)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today's Note")
                            Text(today.path).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
            }
        }
        if !history.pins.isEmpty {
            Section("Pinned") {
                ForEach(history.pins, id: \.[row: "pins"]) { entry in
                    HistoryRow(entry: entry, systemImage: "pin")
                        .swipeActions {
                            Button("Unpin", systemImage: "pin.slash") {
                                history.togglePin(path: entry.path, title: entry.title)
                            }
                            .tint(.orange)
                        }
                }
                .onMove { history.movePins(from: $0, to: $1) }
            }
        }
        if !listedRecents.isEmpty {
            Section {
                ForEach(listedRecents, id: \.[row: "recents"]) { entry in
                    HistoryRow(entry: entry, systemImage: "clock")
                        .swipeActions {
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                history.removeRecent(entry.path)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    if history.recents.count > Self.recentLimit {
                        RouteLink("Show All", route: Route.recents)
                            .font(.subheadline)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    /// Obsidian's default daily note name.
    static func dayString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    /// The note named after today's date (indexed basename lookup).
    static func findTodaysNote(in session: LibrarySession) async -> NoteSummary? {
        (try? await session.notes.notes(basename: dayString(.now), limit: 5))?.first
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let systemImage: String

    var body: some View {
        RouteLink(Route.note(path: entry.path, anchor: nil)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).lineLimit(2)
                    let folder = (entry.path as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .notePreviewMenu(path: entry.path, title: entry.title)
    }
}

/// Every remembered recent note.
struct RecentNotesView: View {
    @Environment(ReadingHistory.self) private var history
    @State private var confirmClear = false

    var body: some View {
        RouteList {
            ForEach(history.recents) { entry in
                HistoryRow(entry: entry, systemImage: "clock")
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            history.removeRecent(entry.path)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if history.recents.isEmpty {
                ContentUnavailableView("No Recent Notes", systemImage: "clock", description: Text("Notes you read appear here."))
            }
        }
        .navigationTitle("Recent")
        .toolbar {
            if !history.recents.isEmpty {
                Button("Clear", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Clear the list of recent notes?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Recent Notes", role: .destructive) { history.clearRecents() }
        }
    }
}
