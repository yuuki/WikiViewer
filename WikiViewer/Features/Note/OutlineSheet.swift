//
//  OutlineSheet.swift
//  WikiViewer
//
//  The note's headings, with the section on screen marked. Choosing one
//  scrolls the note to it.
//

import SwiftUI

struct OutlineSheet: View {
    typealias Heading = OutlineList.Heading

    let headings: [Heading]
    /// Block id of the heading whose section is on screen.
    let current: Int?
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OutlineList(headings: headings, current: current, onSelect: onSelect)
                .navigationTitle("Outline")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// The last heading at or above the top of the screen. Block ids grow in
    /// document order.
    static func currentHeading(in headingBlockIDs: [Int], top: Int?) -> Int? {
        guard let top else { return headingBlockIDs.first }
        return headingBlockIDs.last { $0 <= top } ?? headingBlockIDs.first
    }
}

/// The headings, indented by level, with the current one marked. Shared by
/// the outline sheet (iOS) and the note inspector (macOS).
struct OutlineList: View {
    struct Heading: Hashable {
        var level: Int
        var text: String
        var blockID: Int
    }

    let headings: [Heading]
    let current: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(headings, id: \.blockID) { heading in
                Button {
                    onSelect(heading.blockID)
                } label: {
                    HStack {
                        Text(heading.text)
                            .chromeFont(.body, weight: heading.level <= 1 ? .semibold : nil)
                            .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                            .padding(.leading, CGFloat(min(max(heading.level - 1, 0), 5)) * 14)
                        Spacer()
                        if heading.blockID == current {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Inset and rounded, like a selection on a glass sheet.
                .listRowBackground(heading.blockID == current ? RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)).padding(.horizontal, 8) : nil)
                .accessibilityAddTraits(heading.blockID == current ? .isSelected : [])
            }
            .listStyle(.plain)
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}
