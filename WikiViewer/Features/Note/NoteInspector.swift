//
//  NoteInspector.swift
//  WikiViewer
//
//  Beside a note on macOS: its outline, the notes that link to it, and its
//  properties and tags, so they stay in view while reading instead of
//  sitting at the end of the note or in a sheet.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct NoteInspector: View {
    enum Pane: String, CaseIterable, Identifiable {
        case outline, backlinks, info
        var id: Self { self }
    }

    let model: NoteModel
    let session: LibrarySession
    /// Block id of the heading whose section is on screen.
    let currentHeading: Int?
    let onSelectHeading: (Int) -> Void
    @Binding var pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $pane) {
                Text("Outline").tag(Pane.outline)
                Text("Backlinks").tag(Pane.backlinks)
                Text("Info").tag(Pane.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch pane {
            case .outline: outline
            case .backlinks: backlinks
            case .info: info
            }
        }
    }

    @ViewBuilder
    private var outline: some View {
        let headings = model.rendered?.headings ?? []
        if headings.isEmpty {
            ContentUnavailableView("No Headings", systemImage: "list.bullet.indent")
        } else {
            OutlineList(headings: headings.map { OutlineList.Heading(level: $0.level, text: $0.text, blockID: $0.blockID) },
                        current: currentHeading, onSelect: onSelectHeading)
        }
    }

    private var backlinks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let path = model.detail?.path {
                    NoteRequestsSection(path: path)
                }
                BacklinksSection(model: model, session: session)
            }
            .padding(12)
        }
    }

    private var info: some View {
        ScrollView {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: 16) {
                    InfoSection("Properties") {
                        if detail.properties.isEmpty {
                            Text("None").foregroundStyle(.secondary).font(.footnote)
                        } else {
                            PropertiesView(properties: detail.properties, noteID: detail.id, links: model.links)
                        }
                    }
                    InfoSection("Tags") {
                        if model.tags.isEmpty {
                            Text("None").foregroundStyle(.secondary).font(.footnote)
                        } else {
                            TagLine(tags: model.tags.map(\.name))
                        }
                    }
                    InfoSection("File") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("Path").foregroundStyle(.secondary)
                                Text(detail.path).textSelection(.enabled)
                            }
                            GridRow {
                                Text("Modified").foregroundStyle(.secondary)
                                Text(detail.modified, format: .dateTime)
                            }
                            GridRow {
                                Text("Size").foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: detail.size, countStyle: .file))
                            }
                        }
                        .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}
