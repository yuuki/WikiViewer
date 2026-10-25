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
    @Environment(\.noteTextScale) private var noteTextScale
    @Environment(\.findHighlight) private var findHighlight
    let block: RenderBlock
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.headingLevelOffset) private var headingLevelOffset

    var body: some View {
        switch block.kind {
        case .heading(let rawLevel, let text):
            // Headings of an embedded note rank below the host's own.
            let level = min(rawLevel + headingLevelOffset, 6)
            Text(math: text.highlightingMatches(of: findHighlight), mathSize: NoteTextScale.mathSize(Self.headingStyle(level), typeSize, scale: noteTextScale))
                .noteFont(Self.headingFont(level))
                .fontWeight(level <= 2 ? .bold : level <= 4 ? .semibold : .medium)
                .foregroundStyle(level >= 6 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                // More space above than below, so a heading groups with the
                // section it introduces rather than the one it ends.
                .padding(.top, level <= 2 ? 16 : 8)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            let hasFootnotes = text.runs.contains { $0[FootnoteAttribute.self] != nil }
            Text(math: text.highlightingMatches(of: findHighlight), mathSize: NoteTextScale.mathSize(.body, typeSize, scale: noteTextScale),
                 markingLinks: Self.previewsLinks || hasFootnotes)
                .noteFont(.body)
                .lineSpacing(NoteTextScale.lineSpacing(scale: noteTextScale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .linkPreviewsOnHover()
                .footnotePreviews(hasFootnotes)
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
        case .math(let latex):
            MathBlockView(latex: latex)
        case .mermaid(let chart, let source):
            MermaidView(chart: chart, source: source)
        case .html(let raw):
            Text(raw)
                .noteFont(.noteDetail, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// macOS previews a link's note on ⌘-hover (LinkHoverPreview).
    static var previewsLinks: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Shared by code blocks, callouts, embeds and attachments.
    static let cornerRadius: CGFloat = 10

    /// Never smaller than body text, so a deep heading still ranks above the
    /// paragraph it introduces; H5 and H6 differ by weight and color only.
    static func headingFont(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    static func headingStyle(_ level: Int) -> MathRenderer.TextStyle {
        switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

/// `$$…$$` display math: centered, and scrollable when wider than the page.
/// A formula SwiftMath cannot typeset is shown as its source.
struct MathBlockView: View {
    @Environment(\.noteTextScale) private var noteTextScale
    let latex: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let rendered = MathRenderer.render(latex, fontSize: NoteTextScale.mathSize(.body, typeSize, scale: noteTextScale), display: true) {
            ViewThatFits(in: .horizontal) {
                rendered.image
                    .frame(maxWidth: .infinity)
                HorizontalScroll {
                    rendered.image
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: latex))
        } else {
            CodeBlockView(language: "latex", code: latex)
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
        .noteFont(.body)
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
                    .noteFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            HorizontalScroll {
                Text(code)
                    .noteFont(.noteDetail, design: .monospaced)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformSecondaryBackground, in: .rect(cornerRadius: BlockView.cornerRadius))
    }
}

struct CalloutView: View {
    @Environment(\.noteTextScale) private var noteTextScale
    @Environment(\.findHighlight) private var findHighlight
    let type: String
    let title: AttributedString
    let foldable: Bool
    let children: [RenderBlock]
    @State private var expanded = true
    @Environment(\.dynamicTypeSize) private var typeSize

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
        .padding(.vertical, 10)
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle().fill(style.color).frame(width: 3)
        }
        .clipShape(.rect(cornerRadius: BlockView.cornerRadius))
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: style.symbol)
            Text(math: title.highlightingMatches(of: findHighlight), mathSize: NoteTextScale.mathSize(.body, typeSize, scale: noteTextScale)).fontWeight(.semibold)
            if foldable {
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").noteFont(.caption)
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
        case "question", "help", "faq": ("questionmark.circle", .yellow)
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
    @Environment(\.noteTextScale) private var noteTextScale
    @Environment(\.findHighlight) private var findHighlight
    let header: [AttributedString]
    let rows: [[AttributedString]]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HorizontalScroll {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(math: cell.highlightingMatches(of: findHighlight), mathSize: NoteTextScale.mathSize(.noteDetail, typeSize, scale: noteTextScale)).noteFont(.noteDetail, weight: .bold)
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(math: cell.highlightingMatches(of: findHighlight), mathSize: NoteTextScale.mathSize(.noteDetail, typeSize, scale: noteTextScale)).noteFont(.noteDetail)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
    }
}

/// Wide content (code, tables, display math) scrolls sideways; printed,
/// where a scroll view draws nothing, it is drawn as it is.
struct HorizontalScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.isPrinting) private var isPrinting

    var body: some View {
        if isPrinting {
            content
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}

extension EnvironmentValues {
    /// Added to heading levels, so an embedded note's "# Title" does not
    /// outrank the headings of the note it is shown in.
    @Entry var headingLevelOffset = 0
}

extension View {
    /// ⌘-hover previews of the links in a paragraph (macOS).
    @ViewBuilder
    func linkPreviewsOnHover() -> some View {
        #if os(macOS)
        linkHoverPreviews()
        #else
        self
        #endif
    }
}
