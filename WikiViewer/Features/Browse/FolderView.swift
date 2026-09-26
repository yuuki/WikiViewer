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
    @State private var model = FolderModel()
    @State private var today: NoteSummary?
    @State private var viewingAsset: AssetInfo?
    /// Refreshed every minute so the snapshot's age stays right.
    @State private var now = Date.now

    var body: some View {
        List {
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
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
                    if model.foldersTruncated {
                        Text("More subfolders not shown").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    // Only needed to set the vault apart from the home sections.
                    if path.isEmpty { Text("Folders") }
                }
            }
            Section {
                ForEach(model.notes) { note in
                    NavigationLink(value: Route.note(path: note.path, anchor: nil)) {
                        Label(note.title, systemImage: "doc.text")
                            .lineLimit(2)
                    }
                    .onAppear {
                        if note.id == model.notes.last?.id, let session = library.session {
                            Task { await model.loadMoreNotes(session: session) }
                        }
                    }
                }
            } header: {
                if path.isEmpty, !model.notes.isEmpty { Text("Notes") }
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
            if model.loaded, model.folders.isEmpty, model.notes.isEmpty, model.assets.isEmpty, model.error == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .navigationTitle(path.isEmpty ? "Vault" : VaultPath.fileName(of: path))
        .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
        .fullScreenCover(item: $viewingAsset) { AssetViewer(asset: $0) }
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
            await model.load(path: path, session: session)
            if path.isEmpty { today = await LibraryHomeSections.findTodaysNote(in: session) }
        }
    }
}

extension FolderView {
    private var freshness: Text? {
        SnapshotFreshness(status: library.updateStatus, published: library.session?.info.createdDate).text(now: now)
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
    private(set) var hasMoreNotes = false
    private(set) var loaded = false
    private(set) var error: String?
    private var folderID: Int64?
    private var sessionID: String?
    private var loadingMore = false

    static let pageSize = 200

    func load(path: String, session: LibrarySession) async {
        do {
            guard let id = try await session.folders.folderID(path: path) else {
                error = "This folder is not in the current snapshot."
                folders = []; notes = []; assets = []; loaded = true
                return
            }
            folderID = id
            sessionID = session.id
            let subfolders = try await session.folders.subfolders(of: id)
            let page = try await session.folders.notes(in: id, limit: Self.pageSize)
            let assetPage = try await session.folders.assets(in: id, limit: 100)
            folders = subfolders.items
            foldersTruncated = subfolders.hasMore
            notes = page.items
            hasMoreNotes = page.hasMore
            assets = assetPage.items
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func loadMoreNotes(session: LibrarySession) async {
        // Never mix pages from two generations (ids/cursors differ).
        guard hasMoreNotes, !loadingMore, session.id == sessionID, let folderID, let last = notes.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await session.folders.notes(in: folderID, after: TitleCursor(after: last), limit: Self.pageSize) {
            notes.append(contentsOf: page.items)
            hasMoreNotes = page.hasMore
        }
    }
}
