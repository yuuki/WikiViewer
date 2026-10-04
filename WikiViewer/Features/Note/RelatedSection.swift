//
//  RelatedSection.swift
//  WikiViewer
//
//  A note's neighbours by role (#38): backlinks say only where a note is
//  cited from; these say what it builds on, what supports or contradicts
//  it, and what sits next to it in its topic — to choose what to read next.
//

import SwiftUI
import WikiViewerKit

struct RelatedSection: View {
    let groups: [RelatedGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if groups.isEmpty {
                Text("No related notes for this note.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Label(Self.title(group.role), systemImage: Self.symbol(group.role))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Self.tint(group.role))
                    ForEach(group.items) { item in
                        RouteLink(Route.note(path: item.note.path, anchor: nil)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.note.title)
                                    .font(.body)
                                    .lineLimit(2)
                                if let why = item.why {
                                    Text(LearningPath.readable(why))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 24)
                            .padding(.vertical, 2)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .notePreviewMenu(path: item.note.path, title: item.note.title)
                    }
                }
            }
        }
    }

    /// wiki-related's roles: definition (what the note builds on),
    /// evidence (sources), contradiction (sources or pages in conflict),
    /// cluster (peers in the same topic).
    static func title(_ role: String) -> LocalizedStringKey {
        switch role {
        case "definition": "Builds On"
        case "evidence": "Evidence"
        case "contradiction": "In Conflict"
        case "cluster": "Same Topic"
        default: LocalizedStringKey(role)
        }
    }

    static func symbol(_ role: String) -> String {
        switch role {
        case "definition": "arrow.up.to.line"
        case "evidence": "doc.text.magnifyingglass"
        case "contradiction": "arrow.left.arrow.right"
        case "cluster": "circle.grid.3x3"
        default: "link"
        }
    }

    static func tint(_ role: String) -> Color {
        role == "contradiction" ? .red : .secondary
    }
}
