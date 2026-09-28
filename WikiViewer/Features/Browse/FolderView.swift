//
//  FolderView.swift
//  WikiViewer
//
//  One folder level at a time: subfolders + a keyset-paginated page of notes.
//  Deeper levels are only queried when the user navigates into them.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct FolderView: View {
    let path: String
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
    @State private var model = FolderModel()
    @State private var today: NoteSummary?
    @State private var viewingAsset: AssetInfo?
    /// Refreshed every minute so the snapshot's age stays right.
    @State private var now = Date.now
    @State private var order: NoteOrder = .titleAscending

    var body: some View {
        List {
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
            }
            if path.isEmpty, library.source == .bundledDemo {
                DemoVaultBanner()
            }
            if path.isEmpty, case .failed(let message) = library.updateStatus {
                UpdateFailureBanner(message: message)
            }
            if path.isEmpty {
                LibraryHomeSections(today: today)
            }
            if !model.folders.isEmpty {
                Section {
                    ForEach(model.folders) { folder in
                        NavigationLink(value: Route.folder(path: folder.path)) {
                            FolderRow(folder: folder)
                        }
                    }
                    if model.foldersTruncated, let session = library.session {
                        Button("Show More Folders") {
                            Task { await model.loadMoreFolders(session: session) }
                        }
                    }
                } header: {
                    // Only needed to set the vault apart from the home sections.
                    if path.isEmpty { Text("Folders") }
                }
            }
            // Bases list notes, like folders do: they come before the notes.
            if !model.bases.isEmpty {
                Section("Bases") {
                    ForEach(model.bases) { base in
                        NavigationLink(value: Route.base(path: base.path)) {
                            Label(VaultPath.basename(of: base.name), systemImage: AttachmentRow.symbol(for: .base))
                        }
                    }
                }
            }
            Section {
                ForEach(model.notes) { note in
                    NavigationLink(value: Route.note(path: note.path, anchor: nil)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).lineLimit(2)
                                if order == .modifiedNewest, let modified = note.modified {
                                    Text(modified, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                    .notePreviewMenu(path: note.path, title: note.title)
                    .onAppear {
                        if note.id == model.notes.last?.id, let session = library.session {
                            Task { await model.loadMoreNotes(session: session) }
                        }
                    }
                }
            } header: {
                if path.isEmpty || !model.bases.isEmpty, !model.notes.isEmpty { Text("Notes") }
            } footer: {
                if model.hasMoreNotes {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            if !model.assets.isEmpty {
                Section("Attachments") {
                    ForEach(model.assets) { asset in
                        // Every attachment opens: images in the viewer,
                        // others to say why there is no preview.
                        Button { viewingAsset = asset } label: {
                            AttachmentListRow(asset: asset)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.loaded, model.folders.isEmpty, model.notes.isEmpty, model.assets.isEmpty, model.bases.isEmpty, model.error == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .navigationTitle(path.isEmpty ? String(localized: "Vault") : VaultPath.fileName(of: path))
        .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
        .fullScreenCover(item: $viewingAsset) { AssetViewer(asset: $0) }
        .toolbar {
            if path.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { app.showSettings() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // One tap shows the orders (not a submenu of an overflow menu).
                Menu {
                    Picker("Sort Notes", selection: $order) {
                        Text("Name (A–Z)").tag(NoteOrder.titleAscending)
                        Text("Name (Z–A)").tag(NoteOrder.titleDescending)
                        if model.canSortByModified {
                            Text("Recently Modified").tag(NoteOrder.modifiedNewest)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort Notes", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .onChange(of: order) {
            // The first load sets `order` from the store; it already loaded.
            guard order != model.order, let session = library.session else { return }
            FolderSortStore.setOrder(order, for: path)
            Task { await model.load(path: path, order: order, session: session) }
        }
        .navigationSubtitle(path.isEmpty ? freshness ?? Text(verbatim: "") : Text(verbatim: ""))
        .task(id: path.isEmpty) {
            guard path.isEmpty else { return }
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: library.session?.id) {
            guard let session = library.session else { return }
            order = FolderSortStore.order(for: path)
            await model.load(path: path, order: order, session: session)
            if path.isEmpty { today = await LibraryHomeSections.findTodaysNote(in: session) }
        }
    }
}

extension FolderView {
    private var freshness: Text? {
        SnapshotFreshness(status: library.updateStatus, published: library.session?.info.createdDate).text(now: now)
    }
}

/// The note order chosen for each folder (daily notes read best newest
/// first, most folders A–Z).
enum FolderSortStore {
    static let key = "WikiViewer.folderSort"
    /// Folders whose order is remembered.
    static let limit = 500

    static func order(for path: String) -> NoteOrder {
        let orders = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return orders[path].flatMap(NoteOrder.init(rawValue:)) ?? .titleAscending
    }

    static func setOrder(_ order: NoteOrder, for path: String) {
        var orders = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        orders[path] = order == .titleAscending ? nil : order.rawValue
        if orders.count > limit { orders.removeValue(forKey: orders.keys.first!) }
        UserDefaults.standard.set(orders, forKey: key)
    }
}

struct AttachmentListRow: View {
    let asset: AssetInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: AttachmentRow.symbol(for: asset.kind))
        }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)
        if asset.kind == .image, asset.blobSHA256 == nil {
            return String(localized: "\(size) · Not included in the snapshot")
        }
        if asset.kind != .image {
            return String(localized: "\(size) · No preview")
        }
        return size
    }
}

struct FolderRow: View {
    let folder: FolderSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                if let contents {
                    contents
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "folder")
        }
    }

    /// "12 notes · 2 folders · 3 attachments": a bare total said nothing
    /// about what it counted.
    private var contents: Text? {
        var parts: [Text] = []
        if folder.noteCount > 0 { parts.append(Text("^[\(folder.noteCount) note](inflect: true)")) }
        if folder.folderCount > 0 { parts.append(Text("^[\(folder.folderCount) folder](inflect: true)")) }
        if folder.assetCount > 0 { parts.append(Text("^[\(folder.assetCount) attachment](inflect: true)")) }
        guard var text = parts.first else { return nil }
        for part in parts.dropFirst() { text = Text("\(text) · \(part)") }
        return text
    }
}

@Observable
final class FolderModel {
    private(set) var folders: [FolderSummary] = []
    private(set) var foldersTruncated = false
    private(set) var notes: [NoteSummary] = []
    private(set) var assets: [AssetInfo] = []
    /// `.base` files: they open as a screen, not as an attachment.
    private(set) var bases: [AssetInfo] = []
    private(set) var hasMoreNotes = false
    private(set) var loaded = false
    /// Recently Modified is offered only where it is cheap (no index).
    private(set) var canSortByModified = false
    private(set) var order: NoteOrder = .titleAscending
    private(set) var error: String?
    private var folderID: Int64?
    private var sessionID: String?
    private var loadingMore = false

    static let pageSize = 200

    func load(path: String, order: NoteOrder, session: LibrarySession) async {
        self.order = order
        do {
            guard let id = try await session.folders.folderID(path: path) else {
                error = "This folder is not in the current snapshot."
                folders = []; notes = []; assets = []; bases = []; loaded = true
                return
            }
            folderID = id
            sessionID = session.id
            let subfolders = try await session.folders.subfolders(of: id)
            let page = try await session.folders.notes(in: id, order: order, limit: Self.pageSize)
            canSortByModified = FolderRepository.canSortByModified(noteCount: try await session.folders.folder(id: id)?.noteCount ?? 0)
            let assetPage = try await session.folders.assets(in: id, limit: 100)
            folders = subfolders.items
            foldersTruncated = subfolders.hasMore
            notes = page.items
            hasMoreNotes = page.hasMore
            assets = assetPage.items.filter { $0.kind != .base }
            bases = assetPage.items.filter { $0.kind == .base }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func loadMoreFolders(session: LibrarySession) async {
        guard foldersTruncated, session.id == sessionID, let folderID, let last = folders.last else { return }
        if let page = try? await session.folders.subfolders(of: folderID, after: last) {
            folders.append(contentsOf: page.items)
            foldersTruncated = page.hasMore
        }
    }

    func loadMoreNotes(session: LibrarySession) async {
        // Never mix pages from two generations (ids/cursors differ).
        guard hasMoreNotes, !loadingMore, session.id == sessionID, let folderID, let last = notes.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await session.folders.notes(in: folderID, order: order, after: NoteCursor(after: last), limit: Self.pageSize) {
            notes.append(contentsOf: page.items)
            hasMoreNotes = page.hasMore
        }
    }
}
