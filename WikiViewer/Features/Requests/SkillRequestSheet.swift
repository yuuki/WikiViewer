//
//  SkillRequestSheet.swift
//  WikiViewer
//
//  Runs one of the vault's own agent skills on the Mac. The skills come
//  from the catalog the Mac publishes next to the request statuses; the
//  request is queued like any other and its result, if the skill writes a
//  note, arrives with a later snapshot.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct SkillRequestSheet: View {
    /// The note (and paragraphs) the skill is run on, if any.
    var draft: AskDraft?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var filter = ""
    @State private var text = ""
    @State private var includesNote = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    Section("About") {
                        Toggle(isOn: $includesNote) {
                            LabeledContent("Note", value: draft.noteTitle)
                        }
                        if includesNote {
                            if let heading = draft.heading {
                                LabeledContent("Section", value: heading)
                            }
                            if let excerpt = draft.excerpt {
                                Text(excerpt)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                            }
                        }
                    }
                }
                Section {
                    TextField(skill?.argumentHint ?? String(localized: "What to pass the skill (optional)"), text: $text, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Input")
                } footer: {
                    if let skill {
                        if skill.usesWeb == true {
                            Text("Runs \(Text(verbatim: "/" + skill.name)), which may fetch from the web.")
                        } else {
                            Text("Runs \(Text(verbatim: "/" + skill.name)).")
                        }
                    }
                }
                Section {
                    skillList
                } header: {
                    Text("Skill")
                } footer: {
                    Text(footer)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Run Skill")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run", action: send)
                        .disabled(!library.acceptsRequests || skill == nil)
                }
            }
        }
        .task { await library.loadSkills() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 640)
        #endif
    }

    private var skill: SkillCatalog.Skill? { selected.flatMap { library.skills.catalog?.skill(named: $0) } }

    @ViewBuilder
    private var skillList: some View {
        let state = library.skills
        if !library.acceptsRequests {
            Text("No skills are offered here.")
                .foregroundStyle(.secondary)
        } else if let catalog = state.catalog, !catalog.skills.isEmpty {
            TextField("Filter", text: $filter)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            let shown = matching(catalog.skills)
            ForEach(shown) { skill in
                SkillRow(skill: skill, isSelected: skill.name == selected) {
                    selected = skill.name == selected ? nil : skill.name
                }
            }
            if shown.isEmpty {
                Text("No skill matches “\(filter)”.")
                    .foregroundStyle(.secondary)
            }
        } else if state.catalog == nil, state.error == nil || state.isLoading {
            HStack {
                ProgressView()
                Text("Reading the skills your Mac offers…").foregroundStyle(.secondary)
            }
        } else if let error = state.error, state.catalog == nil {
            Text(error).foregroundStyle(.red)
            Button("Try Again") { Task { await library.loadSkills() } }
        } else {
            Text("Your Mac offers no skills. Run wikiindex requests with a runner in the vault that has .claude/skills.")
                .foregroundStyle(.secondary)
        }
    }

    private func matching(_ skills: [SkillCatalog.Skill]) -> [SkillCatalog.Skill] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }

    private var footer: String {
        if !library.acceptsRequests {
            return String(localized: "The demo vault cannot take requests. Connect the folder or address your Mac publishes to.")
        }
        return String(localized: "Claude on your Mac runs the skill in the vault, writing only under wiki/. Only skills marked with a globe may use the web. A note it writes arrives with a later snapshot; Requests shows its progress.")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard let skill else { return }
        let note = includesNote ? draft : nil
        let request = HostRequest(kind: .skill, device: DeviceName.current, notePath: note?.notePath, noteTitle: note?.noteTitle,
                                  heading: note?.heading, excerpt: note?.excerpt,
                                  text: trimmed.isEmpty ? nil : String(trimmed.prefix(HostRequest.maximumTextLength)), skill: skill.name)
        do {
            try library.submit(request)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// One skill in the picker: its name and what it does.
private struct SkillRow: View {
    let skill: SkillCatalog.Skill
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.body.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                        if skill.usesWeb == true {
                            Image(systemName: "globe")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Uses the web")
                        }
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(isSelected ? 8 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
