//
//  RequestsView.swift
//  WikiViewer
//
//  Requests to the Mac's Claude (HostRequest) and where each one stands:
//  waiting to be sent, queued or in progress on the Mac, or answered — the
//  answer being a note that arrives with a later snapshot.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// Every request kept on this device, newest first.
struct RequestsView: View {
    @Environment(Library.self) private var library
    @State private var confirmClear = false
    @State private var requestingPath = false

    var body: some View {
        let entries = library.requests.visibleEntries
        RouteList {
            ForEach(entries) { entry in
                RequestRow(entry: entry)
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            library.requests.remove(id: entry.id)
                        }
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            library.requests.remove(id: entry.id)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Requests", systemImage: "sparkles",
                                       description: Text("Ask Claude about a note from its More menu. Answers arrive as notes."))
            }
        }
        .navigationTitle("Requests")
        .toolbar {
            Button("New Learning Path…", systemImage: "map") { requestingPath = true }
                .disabled(!library.acceptsRequests)
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await library.syncRequests() }
                }
                .disabled(library.requests.isSyncing)
                Button("Clear Finished", systemImage: "checkmark.circle.badge.xmark") { confirmClear = true }
                    .disabled(!entries.contains(where: { $0.phase == .done || $0.phase == .failed }))
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        .confirmationDialog("Remove the finished requests from this list? Their answers stay in the vault.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Finished", role: .destructive) { library.requests.removeFinished() }
        }
        .sheet(isPresented: $requestingPath) { PathRequestSheet() }
        .task { await library.syncRequests() }
        .refreshable { await library.syncRequests() }
    }
}

/// One request: what was asked, about which note, and its state. An
/// answered request opens its answer.
struct RequestRow: View {
    let entry: RequestQueue.Entry
    @Environment(Library.self) private var library
    /// Whether the answer note is in the snapshot on this device.
    @State private var answerArrived = false

    var body: some View {
        Group {
            if entry.request.kind == .explain {
                RouteLink(Route.explanation(id: entry.id)) { content }
            } else if let answer = entry.status?.answerPath, answerArrived {
                RouteLink(Route.note(path: answer, anchor: nil)) { content }
            } else if let note = entry.request.notePath, entry.phase != .done || entry.status?.findings != nil {
                // Until the answer arrives, the note it is about; an
                // explanation's points show here.
                RouteLink(Route.note(path: note, anchor: nil)) { content }
            } else {
                content
            }
        }
        .task(id: TaskKey(session: library.session?.id, answer: entry.status?.answerPath)) {
            guard let answer = entry.status?.answerPath, let session = library.session else { return }
            answerArrived = (try? await session.notes.noteID(path: answer)) != nil
        }
    }

    private struct TaskKey: Equatable {
        var session: String?
        var answer: String?
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.request.summary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                RequestPhaseLabel(entry: entry, answerArrived: answerArrived)
            }
            if let title = entry.request.noteTitle ?? entry.request.notePath.map(VaultPath.basename(of:)) {
                Text("\(Image(systemName: "doc.text")) \(title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let message = entry.status?.message ?? entry.lastError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(entry.phase == .failed || (entry.phase == .waiting && entry.lastError != nil) ? .red : .secondary)
                    .lineLimit(3)
            }
            Text(entry.request.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct RequestPhaseLabel: View {
    let entry: RequestQueue.Entry
    let answerArrived: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .fixedSize()
    }

    private var title: LocalizedStringKey {
        switch entry.phase {
        case .waiting: "Not Sent"
        case .queued: "Queued"
        case .processing: "In Progress"
        case .done: entry.status?.answerPath == nil || answerArrived ? "Answered" : "Arriving"
        case .failed: "Failed"
        }
    }

    private var systemImage: String {
        switch entry.phase {
        case .waiting: "icloud.and.arrow.up"
        case .queued: "tray"
        case .processing: "hourglass"
        case .done: entry.status?.answerPath == nil || answerArrived ? "checkmark.circle" : "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch entry.phase {
        case .failed: .red
        case .done: answerArrived || entry.status?.answerPath == nil ? .green : .secondary
        default: .secondary
        }
    }
}

/// The requests about one note, under the note (iOS) or in its inspector.
struct NoteRequestsSection: View {
    let path: String
    @Environment(Library.self) private var library

    var body: some View {
        let entries = library.requests.visibleEntries.filter { $0.request.notePath == path }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Requests to Claude")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    RouteLink("Show All", route: Route.requests)
                        .font(.subheadline)
                        .fixedSize()
                }
                ForEach(entries) { entry in
                    RequestRow(entry: entry)
                        .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

extension HostRequest {
    /// One line for lists: the question, the subject, or the kind.
    var summary: String {
        switch kind {
        case .ask:
            switch question {
            case .verify: return String(localized: "Is this true?")
            case .premise: return String(localized: "What does this assume?")
            case .counterexample: return String(localized: "Any counterexamples?")
            case .free, nil: return text ?? String(localized: "Question")
            }
        case .path: return String(localized: "Learning path: \(text ?? "")")
        case .explain: return String(localized: "My explanation")
        case .podcast: return String(localized: "Audio episode")
        case .signals: return String(localized: "Reading history")
        }
    }
}

enum DeviceName {
    @MainActor
    static var current: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
