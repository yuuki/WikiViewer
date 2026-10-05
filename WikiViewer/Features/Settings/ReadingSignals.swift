//
//  ReadingSignals.swift
//  WikiViewer
//
//  Sends the reading history to the Mac (#42), where the vault's skills use
//  it to rank what to curate and recommend and to find sources that were
//  read but never folded into a concept. Off unless the reader turns it on;
//  then readings are kept on the device and sent through the request queue
//  when the app goes to the background (at most once an hour) or on demand.
//

import SwiftUI
import WikiShared
import WikiViewerKit

@MainActor
enum ReadingSignals {
    /// Least time between automatic sends.
    static let interval: TimeInterval = 3600

    /// Queues the waiting readings if sharing is on and the last send was
    /// more than `ifDueAfter` seconds ago (0: now).
    static func send(history: ReadingHistory, library: Library, ifDueAfter: TimeInterval = 0) {
        guard history.sharesReadings, history.pendingSignalCount > 0, library.acceptsRequests else { return }
        if let last = history.lastSent, Date.now.timeIntervalSince(last) < ifDueAfter { return }
        guard let request = history.takeSignalsRequest(device: DeviceName.current) else { return }
        try? library.submit(request)
    }
}

/// Settings for sharing the reading history.
struct ReadingHistorySettings: View {
    @Environment(ReadingHistory.self) private var history
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var history = history
        Section {
            Toggle("Share Reading History with Mac", isOn: $history.sharesReadings)
                .disabled(!library.acceptsRequests && !history.sharesReadings)
            if history.sharesReadings {
                LabeledContent("Waiting to Send", value: history.pendingSignalCount.formatted())
                if let lastSent = history.lastSent {
                    LabeledContent("Last Sent") { Text(lastSent, format: .relative(presentation: .named)) }
                }
                Button("Send Now") { ReadingSignals.send(history: history, library: library) }
                    .disabled(history.pendingSignalCount == 0 || !library.acceptsRequests)
            }
        } header: {
            Text("Reading History")
        } footer: {
            Text("When on, the notes you read (path, title, when, how long and how far) and your pinned notes are sent to your Mac about once an hour, through the same queue as requests. The Mac keeps them outside the vault for 180 days, for Claude to prioritize curation and recommendations. Turning it off deletes what has not been sent.")
        }
    }
}
