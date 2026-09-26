//
//  NoteView.swift
//  WikiViewer
//
//  Displays one note. Only this note's body, link rows, tags and the first
//  page of backlinks are loaded; rendering runs off the main actor.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct NoteView: View {
    let path: String
    let anchor: Anchor?
    @Environment(Library.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @Environment(ReadingHistory.self) private var history
    @State private var model = NoteModel()
    /// Top-level block at the top of the screen. Setting it scrolls there,
    /// and it follows the reader's scrolling (outline, reading position).
    /// Unlike ScrollViewReader.scrollTo, the block stays pinned while lazy
    /// rows above it are measured, so a far jump lands where intended.
    @State private var position: Int?
    /// Where to scroll once the scroll view exists: the first layout resets
    /// `position`, so a value set with the first load would be lost.
    @State private var initialPosition: Int?
    @State private var showingOutline = false
    /// Block briefly highlighted after arriving at a search match.
    @State private var highlightedBlock: Int?
    @State private var viewingAsset: AssetInfo?

    var body: some View {
        content
            .navigationTitle(model.detail?.title ?? VaultPath.basename(of: path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The outline is the main way around a long note, so it sits
                // in the toolbar itself rather than behind an overflow menu.
                if let detail = model.detail {
                    ToolbarItem(placement: .secondaryAction) {
                        let pinned = history.isPinned(path)
                        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                            history.togglePin(path: path, title: detail.title)
                        }
                    }
                }
                if let rendered = model.rendered, !rendered.headings.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingOutline = true
                        } label: {
                            Label("Outline", systemImage: "list.bullet.indent")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingOutline) {
                if let rendered = model.rendered {
                    OutlineSheet(headings: rendered.headings.map { OutlineSheet.Heading(level: $0.level, text: $0.text, blockID: $0.blockID) },
                                 current: OutlineSheet.currentHeading(in: rendered.headings.map(\.blockID), top: position)) { blockID in
                        showingOutline = false
                        scroll(to: blockID)
                    }
                }
            }
            .task(id: library.session?.id) {
                guard let session = library.session else { return }
                let firstLoad = await model.load(path: path, session: session)
                if let detail = model.detail { history.recordVisit(path: path, title: detail.title) }
                if firstLoad, let anchor, let target = model.blockID(for: anchor) {
                    initialPosition = target
                    if anchor.text != nil { await flashHighlight(target) }
                } else if firstLoad, anchor == nil, let saved = history.position(of: path),
                          model.rendered?.blocks.contains(where: { $0.id == saved }) == true {
                    // Continue where the reader left this note.
                    initialPosition = saved
                }
            }
            .fullScreenCover(item: $viewingAsset) { AssetViewer(asset: $0) }
            // Notes deeper in the navigation stack keep their rendered blocks
            // only if they are small; large ones are re-rendered on return.
            .onDisappear { model.releaseIfLarge() }
    }

    private func scroll(to block: Int?) {
        guard let block else { return }
        withAnimation(.easeOut(duration: 0.2)) { position = block }
    }

    /// Marks the block a search result opened at, then fades the mark out.
    private func flashHighlight(_ block: Int) async {
        highlightedBlock = block
        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeOut(duration: 0.6)) { highlightedBlock = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView("Not in Snapshot", systemImage: "doc.questionmark", description: Text("\(path) is not in the current snapshot."))
        case .failed(let message):
            ContentUnavailableView("Couldn't Load Note", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let session = library.session, let detail = model.detail, let rendered = model.rendered {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        NoteHeader(detail: detail, tags: model.tags, showsTitle: !Self.startsWithTitleHeading(rendered, title: detail.title))
                            .id("header")
                        ForEach(rendered.blocks) { block in
                            BlockView(block: block)
                                .background {
                                    if highlightedBlock == block.id {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.yellow.opacity(0.3))
                                            .padding(-4)
                                            .transition(.opacity)
                                    }
                                }
                                .id(block.id)
                        }
                        BacklinksSection(model: model, session: session)
                            .id("backlinks")
                            .padding(.top, 24)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // Only blocks have Int ids: with the header or backlinks at
                // the top the position is nil.
                .scrollPosition(id: $position, anchor: .top)
                .onAppear {
                    guard let target = initialPosition else { return }
                    initialPosition = nil
                    Task { position = target }
                }
                .onChange(of: position) {
                    // nil (header or backlinks at the top) keeps the last block.
                    if let position { history.setPosition(position, of: path) }
                }
                .environment(\.openURL, OpenURLAction { url in
                    LinkRouter(session: session, navigation: navigation, currentNoteID: detail.id) { anchor in
                        scroll(to: model.blockID(for: anchor))
                    } openAsset: { id in
                        Task { viewingAsset = try? await session.assets.asset(id: id) }
                    }.handle(url)
                })
            }
        }
    }
}

extension NoteView {
    /// Avoids showing the title twice when the note starts with "# Title".
    static func startsWithTitleHeading(_ rendered: RenderedNote, title: String) -> Bool {
        guard case .heading(1, let text) = rendered.blocks.first?.kind else { return false }
        return String(text.characters) == title
    }
}

@Observable
final class NoteModel {
    enum Phase: Equatable {
        case loading, missing, loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var detail: NoteDetail?
    private(set) var rendered: RenderedNote?
    private(set) var tags: [TagSummary] = []
    private(set) var backlinks: [Backlink] = []
    private(set) var backlinkTotal = 0
    private(set) var backlinksHaveMore = false
    private var loadedKey: String?
    private var loadingMoreBacklinks = false

    static let backlinkPage = 50
    static let backlinkCountCap = 10_000
    /// Rendered notes larger than this are released when off-screen.
    static let retainLimitBytes: Int64 = 256 * 1024

    /// Loads the note unless it is already loaded for this generation.
    /// Returns true if content was (re)loaded.
    @discardableResult
    func load(path: String, session: LibrarySession) async -> Bool {
        let key = session.id + "|" + path
        if loadedKey == key, rendered != nil { return false }
        do {
            guard let id = try await session.notes.noteID(path: path), let detail = try await session.notes.note(id: id) else {
                phase = .missing
                return true
            }
            let links = try await session.links.outgoingLinks(of: id)
            let rendered = await NoteRenderer.renderInBackground(body: detail.body, noteID: id, links: links)
            tags = try await session.tags.tags(of: id)
            let page = try await session.links.backlinks(to: id, limit: Self.backlinkPage)
            backlinkTotal = try await session.links.backlinkCount(to: id, cap: Self.backlinkCountCap)
            backlinks = page.items
            backlinksHaveMore = page.hasMore
            // The body is only needed for rendering; keep the metadata.
            var trimmed = detail
            trimmed.body = ""
            self.detail = trimmed
            self.rendered = rendered
            loadedKey = key
            phase = .loaded
            return true
        } catch is CancellationError {
            return false
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    func releaseIfLarge() {
        guard let detail, detail.size > Self.retainLimitBytes else { return }
        rendered = nil
        loadedKey = nil
    }

    var backlinkTotalLabel: String {
        backlinkTotal >= Self.backlinkCountCap ? "\(Self.backlinkCountCap)+" : "\(backlinkTotal)"
    }

    func loadMoreBacklinks(session: LibrarySession) async {
        guard let id = detail?.id, backlinksHaveMore, !loadingMoreBacklinks, session.id + "|" + (detail?.path ?? "") == loadedKey else { return }
        loadingMoreBacklinks = true
        defer { loadingMoreBacklinks = false }
        if let page = try? await session.links.backlinks(to: id, before: backlinks.last?.id, limit: Self.backlinkPage) {
            backlinks += page.items
            backlinksHaveMore = page.hasMore
        }
    }

    func blockID(for anchor: Anchor) -> Int? {
        guard let rendered else { return nil }
        if let block = anchor.blockID { return rendered.blockAnchors[block] }
        if let heading = anchor.heading { return rendered.headingAnchors[HeadingKey.make(heading)] }
        if let text = anchor.text {
            // The whole query as a phrase, else its terms, longest first.
            let terms = TrigramSearchEngine.terms(text).sorted { $0.count > $1.count }
            for candidate in [text] + terms {
                if let block = rendered.firstBlock(containing: candidate) { return block }
            }
        }
        return nil
    }
}

struct NoteHeader: View {
    let detail: NoteDetail
    let tags: [TagSummary]
    let showsTitle: Bool
    @State private var showProperties = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(detail.title)
                    .font(.title.bold())
                    .textSelection(.enabled)
            }
            FolderBreadcrumb(folder: VaultPath.folder(of: detail.path))
            if !tags.isEmpty {
                TagLine(tags: tags.map(\.name))
            }
            if !detail.properties.isEmpty {
                DisclosureGroup(isExpanded: $showProperties) {
                    PropertiesView(properties: detail.properties)
                        .padding(.top, 4)
                } label: {
                    // Primary color: a tinted secondary label reads as disabled.
                    Label("Properties (\(detail.properties.count))", systemImage: "list.bullet.rectangle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .tint(.secondary)
            }
            Divider().padding(.top, 4)
        }
    }
}

/// The note's folder as tappable path components. Nothing for the vault
/// root, where a lone "/" would say nothing.
struct FolderBreadcrumb: View {
    let folder: String

    var body: some View {
        if !folder.isEmpty {
            let components = folder.split(separator: "/").map(String.init)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .accessibilityHidden(true)
                    ForEach(components.indices, id: \.self) { i in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right")
                                .accessibilityHidden(true)
                        }
                        NavigationLink(value: Route.folder(path: components[...i].joined(separator: "/"))) {
                            Text(components[i])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Folder"))
        }
    }
}

struct TagLine: View {
    let tags: [String]

    var body: some View {
        var text = AttributedString()
        for (i, tag) in tags.enumerated() {
            if i > 0 { text.append(AttributedString("  ")) }
            var t = AttributedString("#" + tag)
            t.link = WikiLinkAction.tag(tag).url
            text.append(t)
        }
        return Text(text).font(.footnote)
    }
}

struct PropertiesView: View {
    let properties: [Property]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                GridRow {
                    Text(property.key)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(property.value.displayText)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct BacklinksSection: View {
    let model: NoteModel
    let session: LibrarySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked mentions (\(model.backlinkTotalLabel))")
                .font(.headline)
            if model.backlinks.isEmpty {
                Text("No other notes link here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.backlinks) { backlink in
                NavigationLink(value: Route.note(path: backlink.note.path, anchor: nil)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backlink.note.title)
                        Text(backlink.note.folderPath.isEmpty ? "/" : backlink.note.folderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
            }
            if model.backlinksHaveMore {
                Button("Show more") {
                    Task { await model.loadMoreBacklinks(session: session) }
                }
                .font(.footnote)
            }
        }
    }
}

struct MissingNoteView: View {
    let target: String
    @Environment(Library.self) private var library
    @State private var sources: [NoteSummary] = []

    var body: some View {
        List {
            Section {
                Text("“\(target)” does not exist in the vault snapshot. Obsidian would create it when the link is clicked; this viewer is read-only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Linked from") {
                ForEach(sources) { note in
                    NavigationLink(note.title, value: Route.note(path: note.path, anchor: nil))
                }
            }
        }
        .navigationTitle(target)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.session?.id) {
            sources = (try? await library.session?.links.notesLinkingToMissing(target)) ?? []
        }
    }
}
