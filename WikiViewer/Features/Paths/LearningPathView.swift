//
//  LearningPathView.swift
//  WikiViewer
//
//  Learning paths (#35): the reader names a subject, Claude on the Mac
//  orders the notes the vault already has on it, and the path note shows
//  here as steps with what was read and what to read next. Progress stays
//  on the device (ReadingHistory).
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// The steps of a learning path note, above its text.
struct LearningPathSection: View {
    let pathNote: String
    let path: LearningPath
    let notes: [Int64: NoteSummary]
    @Environment(ReadingHistory.self) private var history

    var body: some View {
        // Read so that reading a step elsewhere updates the marks.
        let _ = history.readRevision
        let readable = path.steps.filter { !$0.isGap }
        let done = readable.filter { isDone($0) }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Learning Path", systemImage: "map")
                    .font(.headline)
                Spacer()
                Text("\(done) of \(readable.count) read")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(done), total: Double(max(readable.count, 1)))
            if let next = readable.first(where: { !isDone($0) }), let note = notes[next.noteID ?? -1] {
                RouteLink(Route.note(path: note.path, anchor: next.heading.map { NoteAnchor(heading: $0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read Next").font(.caption).foregroundStyle(.secondary)
                            Text(note.title).font(.body.weight(.semibold))
                        }
                    } icon: {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.1), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else if done == readable.count, !readable.isEmpty {
                Label("Every step read", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(path.steps) { step in
                    stepRow(step)
                    if step.id != path.steps.last?.id { Divider().padding(.leading, 34) }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private func isDone(_ step: LearningPath.Step) -> Bool {
        guard let id = step.noteID, let note = notes[id] else { return false }
        return history.isStepDone(path: pathNote, step: note.path)
    }

    @ViewBuilder
    private func stepRow(_ step: LearningPath.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if step.isGap {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                    .accessibilityLabel(Text("Missing material"))
            } else if let id = step.noteID, let note = notes[id] {
                let done = history.isStepDone(path: pathNote, step: note.path)
                Button {
                    history.setStepDone(!done, path: pathNote, step: note.path)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? Text("Mark as not read") : Text("Mark as read"))
            }
            VStack(alignment: .leading, spacing: 2) {
                if step.isGap {
                    Text("Bridge needed").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(step.detail.isEmpty ? step.text : step.detail).font(.subheadline)
                } else if let id = step.noteID, let note = notes[id] {
                    RouteLink(Route.note(path: note.path, anchor: step.heading.map { NoteAnchor(heading: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.number). \(note.title)").font(.subheadline.weight(.medium))
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// Asks Claude on the Mac for a learning path on a subject.
struct PathRequestSheet: View {
    /// The note the request starts from, if any.
    var notePath: String?
    var noteTitle: String?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @FocusState private var focused: Bool
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject", text: $subject, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                } header: {
                    Text("What do you want to understand?")
                } footer: {
                    Text("Claude on your Mac orders the notes the vault has on this subject, each after what it builds on, and marks where a bridging source is missing. The path arrives as a note under wiki/paths.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Learning Path")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(!library.acceptsRequests || trimmed.isEmpty)
                }
            }
        }
        .onAppear {
            if subject.isEmpty, let noteTitle { subject = noteTitle }
            focused = true
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 300)
        #endif
    }

    private var trimmed: String { subject.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let request = HostRequest(kind: .path, device: DeviceName.current, notePath: notePath, noteTitle: noteTitle, text: trimmed)
        do {
            try library.submit(request)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Paths in the vault's `wiki/paths` folder, newest first, on the home list.
struct LearningPathsHomeSection: View {
    static let folder = "wiki/paths"
    static let limit = 5
    let paths: [NoteSummary]
    let hasMore: Bool

    var body: some View {
        if !paths.isEmpty {
            Section {
                ForEach(paths, id: \.[row: "paths"]) { note in
                    RouteLink(Route.note(path: note.path, anchor: nil)) {
                        Label(note.title, systemImage: "map")
                    }
                }
                if hasMore {
                    RouteLink("Show All", route: Route.folder(path: Self.folder))
                }
            } header: {
                Text("Learning Paths")
            }
            .listRowSection("paths")
        }
    }
}
