//
//  AskClaudeSheet.swift
//  WikiViewer
//
//  Asks the Mac's Claude about a note or some of its paragraphs. The
//  request is queued on the device (sent when the source can be reached)
//  and answered as a note under wiki/ in the vault.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// What a question is about: a note, and optionally paragraphs of it.
struct AskDraft: Identifiable {
    let id = UUID()
    var notePath: String
    var noteTitle: String
    /// The heading the paragraphs are under.
    var heading: String?
    /// The selected paragraphs as plain text; nil for the whole note.
    var excerpt: String?
}

struct AskClaudeSheet: View {
    let draft: AskDraft
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var question: HostRequest.Question = .verify
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Note", value: draft.noteTitle)
                    if let heading = draft.heading {
                        LabeledContent("Section", value: heading)
                    }
                    if let excerpt = draft.excerpt {
                        Text(excerpt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }
                Section {
                    Picker("Question", selection: $question) {
                        Text("Is this true?").tag(HostRequest.Question.verify)
                        Text("What does this assume?").tag(HostRequest.Question.premise)
                        Text("Any counterexamples?").tag(HostRequest.Question.counterexample)
                        Text("My own question").tag(HostRequest.Question.free)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    TextField(question == .free ? "Question" : "Details (optional)", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Question")
                } footer: {
                    Text(footer)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ask Claude")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(!library.acceptsRequests || (question == .free && trimmed.isEmpty))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480)
        #endif
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var footer: String {
        if !library.acceptsRequests {
            return String(localized: "The demo vault cannot take requests. Connect the folder or address your Mac publishes to.")
        }
        return question == .verify
            ? String(localized: "Claude on your Mac judges the claim against the wiki's sources and writes the verdict as a note under wiki/questions.")
            : String(localized: "Claude on your Mac answers in a note under wiki/. It arrives with a later snapshot; Requests shows its progress. Offline, the request waits on this device.")
    }

    private func send() {
        let request = HostRequest(kind: .ask, device: DeviceName.current, notePath: draft.notePath, noteTitle: draft.noteTitle,
                                  heading: draft.heading, excerpt: draft.excerpt.map { String($0.prefix(HostRequest.maximumTextLength)) },
                                  question: question, text: trimmed.isEmpty ? nil : trimmed)
        do {
            try library.submit(request)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// The paragraphs chosen in a note, turned into a draft.
enum AskSelection {
    /// Plain text of the selected top-level blocks, in note order, with the
    /// heading the first one is under.
    static func draft(path: String, title: String, rendered: RenderedNote?, selected: Set<Int>) -> AskDraft {
        guard let rendered, !selected.isEmpty else { return AskDraft(notePath: path, noteTitle: title) }
        let blocks = rendered.blocks.filter { selected.contains($0.id) }
        let excerpt = blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let first = blocks.first?.id ?? 0
        let heading = rendered.headings.last { $0.blockID <= first }?.text
        return AskDraft(notePath: path, noteTitle: title, heading: heading,
                        excerpt: excerpt.isEmpty ? nil : String(excerpt.prefix(HostRequest.maximumTextLength)))
    }
}

/// Shown over a note while paragraphs are being chosen.
struct AskSelectionBar: View {
    let count: Int
    let onCancel: () -> Void
    let onAsk: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(count == 0 ? "Tap paragraphs to ask about, or ask about the whole note." : "\(count) selected")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: onCancel)
            Button(count == 0 ? "Ask About Note…" : "Ask…", action: onAsk)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
