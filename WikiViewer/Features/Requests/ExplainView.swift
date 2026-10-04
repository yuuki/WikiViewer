//
//  ExplainView.swift
//  WikiViewer
//
//  "Explain it" (#41): after reading a note, the reader explains it in
//  their own words (typed, or dictated with the keyboard's microphone —
//  only the text is sent). Claude on the Mac compares the explanation with
//  the note and returns only what was left out and what was got wrong,
//  each pointing at a heading of the note. The points come back in the
//  request's status; nothing is written to the vault.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct ExplainSheet: View {
    let notePath: String
    let noteTitle: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("In your own words…", text: $text, axis: .vertical)
                        .lineLimit(8...20)
                        .focused($focused)
                } header: {
                    Text("Explain “\(noteTitle)”")
                } footer: {
                    Text("Write or dictate (the keyboard's microphone) the main points as you would explain them to someone. Claude on your Mac compares them with the note and returns only what is missing or wrong. Only the text is sent; nothing is saved in the vault.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Explain It")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(!library.acceptsRequests || trimmed.count < 20)
                }
            }
        }
        .onAppear { focused = true }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420)
        #endif
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let request = HostRequest(kind: .explain, device: DeviceName.current, notePath: notePath, noteTitle: noteTitle,
                                  text: String(trimmed.prefix(HostRequest.maximumTextLength)))
        do {
            try library.submit(request)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// What Claude found in an explanation: points missed and points got
/// wrong, each opening the note at its heading.
struct ExplanationView: View {
    let id: UUID
    @Environment(Library.self) private var library
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if let entry = library.requests.entry(id: id) {
            List {
                Section("Your Explanation") {
                    Text(entry.request.text ?? "").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                switch entry.phase {
                case .done:
                    let findings = entry.status?.findings ?? []
                    if findings.isEmpty {
                        Section {
                            Label(entry.status?.message ?? String(localized: "Nothing missing or wrong."), systemImage: "checkmark.seal")
                                .foregroundStyle(.green)
                        }
                    }
                    findingSection("Missing", findings.filter { $0.kind == .missing }, entry: entry, symbol: "circle.dashed", tint: .orange)
                    findingSection("Misunderstood", findings.filter { $0.kind == .misconception }, entry: entry, symbol: "exclamationmark.triangle", tint: .red)
                    if let message = entry.status?.message, !findings.isEmpty {
                        Section { Text(message).font(.footnote) }
                    }
                case .failed:
                    Section { Text(entry.status?.message ?? entry.lastError ?? "").foregroundStyle(.red) }
                default:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Claude on your Mac is reading your explanation. This usually takes a minute or two; you can leave this screen.")
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle(entry.request.noteTitle ?? String(localized: "Explanation"))
            .inlineNavigationTitle()
            .task(id: entry.phase) {
                // Follow the request while it is open.
                while !Task.isCancelled, library.requests.entry(id: id).map({ $0.phase != .done && $0.phase != .failed }) == true {
                    await library.syncRequests()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } else {
            ContentUnavailableView("Request Removed", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func findingSection(_ title: LocalizedStringKey, _ findings: [HostRequestStatus.Finding], entry: RequestQueue.Entry,
                                symbol: String, tint: Color) -> some View {
        if !findings.isEmpty {
            Section(title) {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text(finding.text)
                        } icon: {
                            Image(systemName: symbol).foregroundStyle(tint)
                        }
                        if let heading = finding.heading, let note = entry.request.notePath {
                            Button {
                                openRoute(.note(path: note, anchor: NoteAnchor(heading: heading)))
                            } label: {
                                Label(String(localized: "Go to “\(heading)”"), systemImage: "arrow.turn.down.right")
                                    .font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}
