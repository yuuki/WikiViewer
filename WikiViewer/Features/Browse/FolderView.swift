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

    var body: some View {
        List {
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
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
            } footer: {
                if model.hasMoreNotes {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            if !model.assets.isEmpty {
                Section("Attachments") {
                    ForEach(model.assets) { asset in
                        Label(asset.name, systemImage: asset.kind == .image ? "photo" : "doc")
                            .foregroundStyle(.secondary)
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
        .quickSwitcherToolbar()
        .task(id: library.session?.id) {
            guard let session = library.session else { return }
            await model.load(path: path, session: session)
        }
    }
}

struct FolderRow: View {
    let folder: FolderSummary

    var body: some View {
        HStack {
            Label(folder.name, systemImage: "folder")
            Spacer()
            Text("\(folder.noteCount + folder.folderCount + folder.assetCount)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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
