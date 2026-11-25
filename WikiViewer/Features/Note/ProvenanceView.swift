//
//  ProvenanceView.swift
//  WikiViewer
//
//  The provenance lens (#37): under a note's title, who wrote it, how far
//  it has been checked and how fresh it is, and what it rests on; on a
//  thesis page, the verdict with the way to its evidence table.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct ProvenanceLine: View {
    let provenance: NoteProvenance
    let modified: Date
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) { chips }
                .scrollClipDisabled()
            if hasSources {
                DisclosureGroup(isExpanded: $showsSources) {
                    sources.padding(.top, 4)
                } label: {
                    Label(sourcesTitle, systemImage: "books.vertical")
                        .noteFont(.subheadline)
                        .foregroundStyle(.primary)
                }
                .tint(.secondary)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip(author, systemImage: provenance.author == .claude ? "sparkles" : "person", tint: .secondary)
            if let verification { verification }
            if let status = provenance.status {
                chip(Text(status), systemImage: "leaf", tint: .secondary)
            }
            Text("Updated \((provenance.updatedDate ?? modified).formatted(.relative(presentation: .named)))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .noteFont(.noteDetail)
    }

    private var author: Text {
        provenance.author == .claude ? Text("Written by Claude") : Text("Written by you")
    }

    private var verification: AnyView? {
        switch provenance.verification {
        case .notApplicable: nil
        case .unverified: AnyView(chip(Text("Unverified"), systemImage: "questionmark.circle", tint: .orange))
        case .verified(let date): AnyView(chip(date.map { Text("Verified \($0)") } ?? Text("Verified"), systemImage: "checkmark.seal", tint: .green))
        case .recompiled(let date): AnyView(chip(Text("Recompiled \(date)"), systemImage: "arrow.triangle.2.circlepath", tint: .green))
        case .judged(let date): AnyView(chip(Text("Judged \(date)"), systemImage: "scalemass", tint: .green))
        }
    }

    private func chip(_ text: Text, systemImage: String, tint: Color) -> some View {
        Label { text } icon: { Image(systemName: systemImage) }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: .capsule)
            .lineLimit(1)
            .fixedSize()
    }

    private var hasSources: Bool {
        !provenance.sources.isEmpty || !provenance.originalURLs.isEmpty
    }

    private var sourcesTitle: LocalizedStringKey {
        let count = provenance.evidence.count
        if count > 0 { return "Based on \(count) sources" }
        return "Original"
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(provenance.evidence) { reference in
                if let id = reference.noteID {
                    Text(linked(reference.label, WikiLinkAction.note(id: id, heading: nil, blockID: nil).url))
                } else {
                    Text("\(reference.label) (not in the snapshot)").foregroundStyle(.secondary)
                }
            }
            ForEach(provenance.originals) { reference in
                Label {
                    Text("Original: \(reference.target)").textSelection(.enabled)
                } icon: {
                    Image(systemName: "doc")
                }
                .foregroundStyle(.secondary)
            }
            if !provenance.originals.isEmpty {
                Text("Originals under .raw/ stay on the Mac; they are not in the snapshot.")
                    .chromeFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            if provenance.originalIsPrivate {
                Label("Not for sharing (publish: false)", systemImage: "lock")
                    .chromeFont(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(provenance.originalURLs, id: \.self) { url in
                Link(destination: url) {
                    Label(url.host() ?? url.absoluteString, systemImage: "safari")
                }
            }
        }
        .noteFont(.noteDetail)
    }

    private func linked(_ label: String, _ url: URL?) -> AttributedString {
        var text = AttributedString(label)
        text.link = url
        return text
    }
}

/// A wiki-thesis page's verdict: the claim, how far the wiki's sources
/// support it, and the way to the evidence.
struct ThesisCard: View {
    let thesis: NoteProvenance.Thesis
    /// Headings of the page (block id, text), for the section buttons.
    let headings: [(blockID: Int, text: String)]
    let onJump: (Int) -> Void

    /// The fixed sections of a thesis page (wiki-thesis), in page order.
    static let sections = ["根拠表", "機序", "判定", "反証条件", "差し戻し"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Verdict", systemImage: "scalemass").chromeFont(.headline)
                Spacer()
                Text(verdictTitle)
                    .chromeFont(.subheadline, weight: .semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(verdictColor, in: .capsule)
            }
            if let statement = thesis.statement {
                Text(statement).noteFont(.body).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let confidence = thesis.confidence {
                    Text("Confidence: \(confidence)")
                }
                if let judged = thesis.judged {
                    Text("Judged \(judged)")
                }
            }
            .chromeFont(.footnote)
            .foregroundStyle(.secondary)
            if !thesis.origins.isEmpty {
                ForEach(thesis.origins) { origin in
                    if let id = origin.noteID {
                        Text(originText(origin.label, WikiLinkAction.note(id: id, heading: nil, blockID: nil).url)).chromeFont(.footnote)
                    }
                }
            }
            let available = Self.sections.compactMap { name in headings.first { $0.text.hasPrefix(name) }.map { (name, $0.blockID) } }
            if !available.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(available, id: \.0) { name, block in
                            Button(name) { onJump(block) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(verdictColor.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(verdictColor.opacity(0.3)))
    }

    private func originText(_ label: String, _ url: URL?) -> AttributedString {
        var text = AttributedString(String(localized: "From: "))
        var link = AttributedString(label)
        link.link = url
        text.append(link)
        return text
    }

    private var verdictTitle: LocalizedStringKey {
        switch thesis.verdict {
        case .supported: "Supported"
        case .partially: "Partially Supported"
        case .contradicted: "Contradicted"
        case .insufficient: "Insufficient Evidence"
        case .mixed: "Mixed"
        case nil: LocalizedStringKey(thesis.verdictText ?? "Not Judged")
        }
    }

    private var verdictColor: Color {
        switch thesis.verdict {
        case .supported: .green
        case .partially: .orange
        case .contradicted: .red
        case .mixed: .purple
        case .insufficient, nil: .gray
        }
    }
}
