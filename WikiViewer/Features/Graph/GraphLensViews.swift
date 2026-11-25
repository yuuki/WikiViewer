//
//  GraphLensViews.swift
//  WikiViewer
//
//  The graph as a lens on questions (#39): a cluster's summary and open
//  questions on its card, and the gaps between clusters — dashed links on
//  the map — with the report's reasoning and the literature that would
//  bridge them.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// What a cluster is about and what is still open in it.
struct ClusterLensSection: View {
    let note: ClusterNote?
    let gaps: [GraphGap]
    let onShowGaps: () -> Void
    @State private var showsAllQuestions = false

    var body: some View {
        if let note {
            if let summary = note.summary {
                Text(summary)
                    .chromeFont(.footnote)
                    .lineLimit(showsAllQuestions ? nil : 4)
                if note.isStale {
                    Label("Written before the cluster changed", systemImage: "clock.arrow.circlepath")
                        .chromeFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !note.questions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Questions").chromeFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(Array(note.questions.prefix(showsAllQuestions ? 10 : 2).enumerated()), id: \.offset) { _, question in
                        Label {
                            Text(question).chromeFont(.footnote).lineLimit(showsAllQuestions ? nil : 2)
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                        }
                    }
                    if note.questions.count > 2 || (note.summary?.count ?? 0) > 120 {
                        Button(showsAllQuestions ? "Less" : "More") { showsAllQuestions.toggle() }
                            .chromeFont(.caption)
                    }
                }
            }
        }
        if !gaps.isEmpty {
            Button(action: onShowGaps) {
                Label("Gaps: \(gaps.count)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .chromeFont(.footnote)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
        }
    }
}

/// Gap candidates, each opening its details.
struct GapListView: View {
    let gaps: [GraphGap]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(gaps) { gap in
                NavigationLink {
                    GapDetailView(gap: gap)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(gap.title).chromeFont(.body, weight: .medium)
                        Text([gap.noteA?.title, gap.noteB?.title].compactMap { $0 }.joined(separator: " ⇢ "))
                            .chromeFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if gaps.isEmpty {
                    ContentUnavailableView("No Gaps", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text("The vault's gap reports (wiki-gap) list none for this snapshot."))
                }
            }
            .navigationTitle("Gaps")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}

struct GapDetailView: View {
    let gap: GraphGap
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        List {
            Section {
                Text(gap.title).chromeFont(.headline)
                if let verdict = gap.verdict {
                    LabeledContent("Verdict", value: verdict)
                }
            }
            Section("Between") {
                ForEach([gap.noteA, gap.noteB].compactMap { $0 }, id: \.id) { note in
                    Button {
                        dismiss()
                        openRoute(.note(path: note.path, anchor: nil))
                    } label: {
                        Label(note.title, systemImage: "doc.text")
                    }
                }
            }
            if !gap.detail.isEmpty {
                Section("Why It Is a Gap") {
                    ForEach(Array(gap.detail.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(LearningPath.readable(String(line))).chromeFont(.footnote)
                    }
                }
            }
            if !gap.recommendations.isEmpty {
                Section("Bridging Literature") {
                    ForEach(gap.recommendations, id: \.self) { recommendation in
                        Text(recommendation).chromeFont(.footnote).textSelection(.enabled)
                    }
                }
            }
            if let report = gap.report {
                Section {
                    Button {
                        dismiss()
                        openRoute(.note(path: report.path, anchor: NoteAnchor(text: gap.title)))
                    } label: {
                        Label("Open Gap Report", systemImage: "doc.richtext")
                    }
                }
            }
        }
        .navigationTitle("Gap")
        .inlineNavigationTitle()
    }
}
