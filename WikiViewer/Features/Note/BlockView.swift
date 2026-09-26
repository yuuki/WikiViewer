//
//  BlockView.swift
//  WikiViewer
//
//  Native SwiftUI rendering of RenderBlocks. Text uses Dynamic Type styles;
//  inline emphasis/code/links come from AttributedString attributes.
//

import SwiftUI
import WikiViewerKit

struct BlockView: View {
    let block: RenderBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level))
                .fontWeight(level <= 2 ? .bold : level <= 4 ? .semibold : .medium)
                .foregroundStyle(level >= 6 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.top, level <= 2 ? 10 : 6)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, let continuation):
            CodeBlockView(language: continuation ? nil : language, code: code)
        case .quote(let children):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(children) { BlockView(block: $0) }
                }
                .foregroundStyle(.secondary)
            }
        case .callout(let type, let title, let foldable, let children):
            CalloutView(type: type, title: title, foldable: foldable, children: children)
        case .listItem(let marker, let depth, let blocks):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ListMarkerView(marker: marker)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(blocks) { BlockView(block: $0) }
                }
            }
            .padding(.leading, CGFloat(min(depth, 8)) * 18)
        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 6)
        case .embed(let target):
            EmbedView(target: target)
        case .html(let raw):
            Text(raw)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Never smaller than body text, so a deep heading still ranks above the
    /// paragraph it introduces; H5 and H6 differ by weight and color only.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

struct ListMarkerView: View {
    let marker: ListMarker

    var body: some View {
        Group {
            switch marker {
            case .task(let done):
                Image(systemName: done ? "checkmark.square" : "square")
                    .foregroundStyle(done ? Color.accentColor : .secondary)
            case .number(let n):
                Text("\(n).").monospacedDigit()
            case .bullet:
                Text("•")
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(minWidth: 16, alignment: .trailing)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 4))
    }
}

struct CalloutView: View {
    let type: String
    let title: AttributedString
    let foldable: Bool
    let children: [RenderBlock]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Only a foldable callout is a button: a disabled one would be
            // drawn dimmed and read as unavailable.
            if foldable {
                Button {
                    expanded.toggle()
                } label: {
                    titleRow
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            } else {
                titleRow
            }
            if expanded {
                ForEach(children) { BlockView(block: $0) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle().fill(style.color).frame(width: 3)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: style.symbol)
            Text(title).fontWeight(.semibold)
            if foldable {
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
            }
        }
        .foregroundStyle(titleColor)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The accent darkened (light mode) or lightened (dark mode) toward the
    /// text color, so the title keeps enough contrast on the tinted
    /// background. Yellow needs the strongest shift.
    private var titleColor: Color {
        style.color.mix(with: .primary, by: type == "question" || type == "help" || type == "faq" ? 0.5 : 0.3)
    }

    var style: (symbol: String, color: Color) {
        switch type {
        case "tip", "hint", "important": ("flame", .teal)
        case "success", "check", "done": ("checkmark.circle", .green)
        case "question", "help", "faq": ("questionmark.circle", Color(.systemYellow))
        case "warning", "caution", "attention": ("exclamationmark.triangle", .orange)
        case "failure", "fail", "missing", "danger", "error", "bug": ("xmark.octagon", .red)
        case "example": ("list.bullet", .purple)
        case "quote", "cite": ("quote.opening", .gray)
        case "abstract", "summary", "tldr": ("doc.text", .cyan)
        case "todo": ("checkmark.circle", .blue)
        default: ("info.circle", .blue)
        }
    }
}

struct TableBlockView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.footnote.bold())
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.footnote)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
    }
}
