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
    let anchor: NoteAnchor?
    @Environment(Library.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openRoute) private var openRoute
    @Environment(ReadingHistory.self) private var history
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var app
    @Environment(\.noteTextScale) private var noteTextScale
    @State private var model = NoteModel()
    @State private var find = NoteFind()
    /// Top-level block at the top of the screen. Setting it scrolls there,
    /// and it follows the reader's scrolling (outline, reading position).
    /// Unlike ScrollViewReader.scrollTo, the block stays pinned while lazy
    /// rows above it are measured, so a far jump lands where intended.
    @State private var position: Int?
    /// Where to scroll once the scroll view exists: the first layout resets
    /// `position`, so a value set with the first load would be lost.
    @State private var initialPosition: Int?
    @State private var showingOutline = false
    @AppStorage("WikiViewer.inspectorPane") private var inspectorPane: NoteInspector.Pane = .outline
    /// Block briefly highlighted after arriving at a search match.
    @State private var highlightedBlock: Int?
    @State private var viewingAsset: AssetInfo?
    /// Set once the note has first been shown: a note re-rendered after
    /// `releaseIfLarge` returns to where the reader was, not to `anchor`.
    @State private var arrived = false
    /// Paragraphs chosen to ask Claude about, while choosing (nil otherwise).
    @State private var askSelection: Set<Int>?
    @State private var askDraft: AskDraft?
    @State private var requestingPath = false
    /// When the note came on screen, for the reading history (#42).
    @State private var openedAt: Date?

    var body: some View {
        // The find bar sits above the scroll view, not over it: a match
        // scrolled to the top would otherwise be under the bar.
        VStack(spacing: 0) {
            if find.isShown { NoteFindBar(find: find) }
            if let askSelection {
                AskSelectionBar(count: askSelection.count) {
                    self.askSelection = nil
                } onAsk: {
                    askDraft = AskSelection.draft(path: path, title: model.detail?.title ?? VaultPath.basename(of: path),
                                                  rendered: model.rendered, selected: askSelection)
                    self.askSelection = nil
                }
            }
            content
        }
            .navigationTitle(model.detail?.title ?? VaultPath.basename(of: path))
            .inlineNavigationTitle()
            .toolbar {
                // The outline is the main way around a long note, so it sits
                // in the toolbar itself; the local graph joins the overflow
                // menu, leaving room for the title.
                #if os(macOS)
                // The outline, backlinks and properties are in the inspector.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.showsInspector.toggle()
                    } label: {
                        Label(app.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Outline, backlinks and properties (⌥⌘I)")
                }
                #else
                if let rendered = model.rendered, !rendered.headings.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingOutline = true
                        } label: {
                            Label("Outline", systemImage: "list.bullet.indent")
                        }
                    }
                }
                #endif
                // macOS has it in the note's More menu (NoteActionItems).
                #if os(iOS)
                if model.detail != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Local Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                            openRoute(.localGraph(path: path))
                        }
                    }
                }
                #endif
                if model.detail != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Ask Claude…", systemImage: "sparkles") {
                            find.isShown = false
                            askSelection = []
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Learning Path…", systemImage: "map") { requestingPath = true }
                    }
                }
                if let detail = model.detail, let session = library.session {
                    NoteActionItems(detail: detail, session: session)
                }
            }
            .sheet(isPresented: $showingOutline) {
                if let rendered = model.rendered {
                    OutlineSheet(headings: rendered.headings.map { OutlineSheet.Heading(level: $0.level, text: $0.text, blockID: $0.blockID) },
                                 current: currentHeading) { blockID in
                        showingOutline = false
                        scroll(to: blockID)
                    }
                }
            }
            #if os(macOS)
            .inspector(isPresented: Bindable(app).showsInspector) {
                Group {
                    if let session = library.session, let detail = model.detail {
                        NoteInspector(model: model, session: session, currentHeading: currentHeading,
                                      onSelectHeading: { scroll(to: $0) }, pane: $inspectorPane)
                            .environment(\.openURL, linkAction(session: session, detail: detail))
                    } else {
                        Color.clear
                    }
                }
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
            }
            #endif
            .task(id: library.session?.id) {
                guard let session = library.session else { return }
                let firstLoad = await model.load(path: path, session: session)
                if let detail = model.detail { history.recordVisit(path: path, title: detail.title) }
                guard firstLoad else { return }
                let returning = arrived
                arrived = true
                if !returning, let anchor, let target = model.blockID(for: anchor) {
                    initialPosition = target
                    if anchor.text != nil { await flashHighlight(target) }
                } else if returning || anchor == nil, let saved = history.position(of: path),
                          model.rendered?.blocks.contains(where: { $0.id == saved }) == true {
                    // Continue where the reader left this note.
                    initialPosition = saved
                }
            }
            .assetPresentation(item: $viewingAsset)
            .sheet(item: $askDraft) { AskClaudeSheet(draft: $0) }
            .sheet(isPresented: $requestingPath) {
                PathRequestSheet(notePath: path, noteTitle: model.detail?.title)
            }
            .environment(\.findHighlight, find.isShown ? find.query : "")
            .onChange(of: find.query) { findMatches() }
            .onChange(of: model.rendered?.blocks.count) { if find.isShown { findMatches() } }
            .onChange(of: find.current) { scroll(to: find.currentBlock) }
            .userActivity(NoteActivity.type, element: model.detail) { detail, activity in
                NoteActivity.describe(activity, path: detail.path, title: detail.title)
            }
            .onAppear {
                publishNote()
                openedAt = .now
            }
            .onChange(of: model.detail?.id) { publishNote() }
            // Notes deeper in the navigation stack keep their rendered blocks
            // only if they are small; large ones are re-rendered on return.
            .onDisappear {
                if let openedAt, let detail = model.detail {
                    history.recordReading(path: path, title: detail.title, openedAt: openedAt, seconds: Int(Date.now.timeIntervalSince(openedAt)))
                }
                openedAt = nil
                // The scroll view made on return starts at the top; `position`
                // must change for it to scroll back to the saved block.
                if model.releaseIfLarge() { position = nil }
                // The note pushed over this one has already published itself.
                if navigation.note?.detail.path == path { navigation.note = nil }
            }
    }

    private func blockRow(_ block: RenderBlock) -> some View {
        BlockView(block: block)
            .overlay {
                // While choosing paragraphs, a tap chooses rather than
                // following a link or selecting text.
                if let selection = askSelection {
                    let chosen = selection.contains(block.id)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chosen ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: chosen ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.12) : Color.clear))
                        .padding(-4)
                        .contentShape(.rect)
                        .onTapGesture {
                            if chosen { askSelection?.remove(block.id) } else { askSelection?.insert(block.id) }
                        }
                        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            .background {
                if highlightedBlock == block.id || (find.isShown && find.currentBlock == block.id) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color("Highlight").opacity(0.35))
                        .padding(-4)
                        .transition(.opacity)
                }
            }
            .id(block.id)
    }

    /// The heading whose section is at the top of the screen.
    private var currentHeading: Int? {
        guard let headings = model.rendered?.headings else { return nil }
        return OutlineSheet.currentHeading(in: headings.map(\.blockID), top: position)
    }

    /// Opens the links in the note and in its inspector.
    private func linkAction(session: LibrarySession, detail: NoteDetail) -> OpenURLAction {
        OpenURLAction { url in
            LinkRouter(session: session, openRoute: openRoute, currentNoteID: detail.id) { anchor in
                scroll(to: model.blockID(for: anchor))
            } openAsset: { asset in
                viewingAsset = asset
            }.handle(url)
        }
    }

    private func findMatches() {
        find.update(in: model.rendered)
        scroll(to: find.currentBlock)
    }

    /// Makes this note the target of the Note menu.
    private func publishNote() {
        guard let detail = model.detail, let session = library.session else { return }
        navigation.note = NoteFocus(detail: detail, session: session, openURL: openURL, find: find, model: model)
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
                        // A note that opens with "# Title" keeps that heading as
                        // its title; the folder, tags and properties follow it.
                        let titleBlock = Self.startsWithTitleHeading(rendered, title: detail.title) ? rendered.blocks.first : nil
                        if let titleBlock { blockRow(titleBlock) }
                        NoteHeader(detail: detail, tags: model.tags, links: model.links, showsTitle: titleBlock == nil,
                                   showsProperties: !Self.hasInspector, provenance: model.provenance)
                            .id("header")
                        if let thesis = model.provenance?.thesis {
                            ThesisCard(thesis: thesis, headings: rendered.headings.map { ($0.blockID, $0.text) }) { scroll(to: $0) }
                                .id("thesis")
                        }
                        if let learningPath = model.learningPath {
                            LearningPathSection(pathNote: detail.path, path: learningPath, notes: model.pathNotes)
                                .id("path")
                        }
                        ForEach(rendered.blocks.dropFirst(titleBlock == nil ? 0 : 1)) { block in
                            blockRow(block)
                        }
                        if !Self.hasInspector {
                            if !model.related.isEmpty {
                                RelatedSection(groups: model.related)
                                    .padding(.top, 24)
                            }
                            NoteRequestsSection(path: path)
                                .padding(.top, 24)
                            BacklinksSection(model: model, session: session)
                                .id("backlinks")
                                .padding(.top, 24)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // A readable line length at any text size.
                    .frame(maxWidth: NoteTextScale.readingWidth(scale: noteTextScale), alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // Only blocks have Int ids: with the header or backlinks at
                // the top the position is nil.
                .scrollPosition(id: $position, anchor: .top)
                #if os(macOS)
                .pinchToScaleNoteText()
                #endif
                .onAppear {
                    guard let target = initialPosition else { return }
                    initialPosition = nil
                    Task { position = target }
                }
                .onChange(of: position) {
                    // nil (header or backlinks at the top) keeps the last block.
                    if let position { history.setPosition(position, of: path) }
                }
                .environment(\.embeddedAssets, model.embeddedAssets)
                .environment(\.openURL, linkAction(session: session, detail: detail))
            }
        }
    }
}

extension NoteView {
    /// macOS shows backlinks and properties in the inspector, not in the note.
    static var hasInspector: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

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
    /// Outgoing link rows; the header resolves frontmatter wikilinks with them.
    private(set) var links: [OutgoingLink] = []
    private(set) var backlinks: [Backlink] = []
    private(set) var backlinkTotal = 0
    private(set) var backlinksHaveMore = false
    /// Neighbours by role (#38).
    private(set) var related: [RelatedGroup] = []
    /// Who wrote the note and what it rests on (#37).
    private(set) var provenance: NoteProvenance?
    /// The steps of a learning path note (#35), with their notes.
    private(set) var learningPath: LearningPath?
    private(set) var pathNotes: [Int64: NoteSummary] = [:]
    /// Embedded assets, so image embeds know their size before they load.
    private(set) var embeddedAssets: [Int64: AssetInfo] = [:]
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
            self.links = links
            embeddedAssets = try await session.assets.assets(ids: links.filter(\.isEmbed).compactMap(\.targetAssetID))
            related = (try? await session.related.related(to: id)) ?? []
            provenance = NoteProvenance.make(path: detail.path, properties: detail.properties, links: links)
            if LearningPath.isPath(properties: detail.properties), let path = LearningPath.parse(body: detail.body, links: links) {
                var notes: [Int64: NoteSummary] = [:]
                for noteID in Set(path.steps.compactMap(\.noteID)) {
                    notes[noteID] = try await session.notes.summary(id: noteID)
                }
                learningPath = path
                pathNotes = notes
            } else {
                learningPath = nil
                pathNotes = [:]
            }
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

    /// Returns true if the rendered blocks were released.
    @discardableResult
    func releaseIfLarge() -> Bool {
        guard let detail, detail.size > Self.retainLimitBytes else { return false }
        rendered = nil
        loadedKey = nil
        // Not .loaded: with no blocks the content would be an empty view,
        // which never appears again, so its `.task` would never reload it.
        phase = .loading
        return true
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

    func blockID(for anchor: NoteAnchor) -> Int? {
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
    let links: [OutgoingLink]
    let showsTitle: Bool
    var showsProperties = true
    var provenance: NoteProvenance?
    @State private var showProperties = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(detail.title)
                    .noteFont(.title, weight: .bold)
                    .textSelection(.enabled)
            }
            FolderBreadcrumb(folder: VaultPath.folder(of: detail.path))
            if !tags.isEmpty {
                TagLine(tags: tags.map(\.name))
            }
            if let provenance {
                ProvenanceLine(provenance: provenance, modified: detail.modified)
            }
            if showsProperties, !detail.properties.isEmpty {
                DisclosureGroup(isExpanded: $showProperties) {
                    PropertiesView(properties: detail.properties, noteID: detail.id, links: links)
                        .padding(.top, 4)
                } label: {
                    // Primary color: a tinted secondary label reads as disabled.
                    Label("Properties (\(detail.properties.count))", systemImage: "list.bullet.rectangle")
                        .noteFont(.subheadline)
                        .foregroundStyle(.primary)
                }
                .tint(.secondary)
            }
            // Only under something: a lone rule under the toolbar says nothing.
            if hasMetadata {
                Divider().padding(.top, 4)
            }
        }
    }

    private var hasMetadata: Bool {
        !VaultPath.folder(of: detail.path).isEmpty || !tags.isEmpty || provenance != nil || (showsProperties && !detail.properties.isEmpty)
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
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ForEach(components.indices, id: \.self) { i in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        RouteLink(Route.folder(path: components[...i].joined(separator: "/"))) {
                            Text(components[i])
                                // A caption-sized link is too small to hit.
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .noteFont(.noteDetail)
                .foregroundStyle(.tint)
            }
            // The links' 44pt hit areas overlap the lines around the
            // breadcrumb instead of pushing them apart.
            .scrollClipDisabled()
            .padding(.vertical, -12)
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
        return Text(text).noteFont(.noteDetail)
    }
}

struct PropertiesView: View {
    let properties: [Property]
    let noteID: Int64
    let links: [OutgoingLink]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                GridRow {
                    Text(property.key)
                        .noteFont(.noteDetail)
                        .foregroundStyle(.secondary)
                    value(property.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A list with several items shows one bulleted item per line, so a long
    /// item that wraps is not mistaken for several.
    @ViewBuilder
    private func value(_ value: PropertyValue) -> some View {
        if case .list(let items) = value, items.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        text(item)
                    }
                }
            }
        } else {
            text(value)
        }
    }

    private func text(_ value: PropertyValue) -> some View {
        Text(NoteRenderer.propertyText(value, noteID: noteID, links: links))
            .noteFont(.noteDetail)
            .textSelection(.enabled)
    }
}

struct BacklinksSection: View {
    let model: NoteModel
    let session: LibrarySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked Mentions (\(model.backlinkTotalLabel))")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.backlinks.isEmpty {
                Text("No other notes link here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.backlinks) { backlink in
                BacklinkRow(backlink: backlink, targetID: model.detail?.id, session: session)
                Divider()
            }
            if model.backlinksHaveMore {
                Button("Show More Mentions") {
                    Task { await model.loadMoreBacklinks(session: session) }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One linking note, with the line that links here (loaded when shown).
struct BacklinkRow: View {
    let backlink: Backlink
    let targetID: Int64?
    let session: LibrarySession
    @State private var context: String?

    var body: some View {
        RouteLink(Route.note(path: backlink.note.path, anchor: nil)) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(backlink.note.title)
                        .font(.body.weight(.medium))
                    if let context, !context.isEmpty {
                        Text(context)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !backlink.note.folderPath.isEmpty {
                        Text("\(Image(systemName: "folder")) \(backlink.note.folderPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .notePreviewMenu(path: backlink.note.path, title: backlink.note.title)
        .task(id: backlink.note.id) {
            guard let targetID else { return }
            let line = try? await session.links.backlinkContext(from: backlink.note.id, to: targetID)
            context = line.map(Self.readable)
        }
    }

    /// Shows links as their text: "[[a/b#c|Label]]" → "Label", "[[a/b]]" → "b".
    static func readable(_ line: String) -> String {
        var text = line
        if let wiki = try? Regex(#"!?\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"#) {
            text = text.replacing(wiki) { match in
                if let label = match.output[2].substring, !label.isEmpty { return String(label) }
                let target = match.output[1].substring.map(String.init) ?? ""
                let page = target.split(separator: "#").first.map(String.init) ?? target
                return page.split(separator: "/").last.map(String.init) ?? page
            }
        }
        // Leading list, quote and heading markers.
        while let first = text.first, "-*+>#".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
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
                    RouteLink(note.title, route: Route.note(path: note.path, anchor: nil))
                }
            }
        }
        .navigationTitle(target)
        .inlineNavigationTitle()
        .task(id: library.session?.id) {
            sources = (try? await library.session?.links.notesLinkingToMissing(target)) ?? []
        }
    }
}
