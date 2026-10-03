//
//  NoteActions.swift
//  WikiViewer
//
//  What can be done with a note besides reading it: the way back to
//  Obsidian for editing, sharing and copying.
//

import SwiftUI
import UniformTypeIdentifiers
import WikiShared
import WikiViewerKit

enum ObsidianLink {
    /// Name of the vault in Obsidian, set in Settings (Obsidian URIs need it).
    static let vaultNameKey = "WikiViewer.obsidianVaultName"

    /// `obsidian://open?vault=…&file=…` for a note, or nil without a vault name.
    static func url(vault: String, notePath: String) -> URL? {
        let vault = vault.trimmingCharacters(in: .whitespaces)
        guard !vault.isEmpty else { return nil }
        let file = notePath.hasSuffix(".md") ? String(notePath.dropLast(3)) : notePath
        return URL(string: "obsidian://open?vault=\(encode(vault))&file=\(encode(file))")
    }

    /// Like JavaScript's encodeURIComponent, which Obsidian decodes.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// The note's "More" toolbar items: in the overflow menu on iOS. macOS
/// keeps editing and sharing in the toolbar and the rest in a menu, so the
/// toolbar is not a row of icons that only their tooltips explain.
struct NoteActionItems: ToolbarContent {
    let detail: NoteDetail
    let session: LibrarySession
    @Environment(ReadingHistory.self) private var history
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.openRoute) private var openRoute
    @AppStorage(ObsidianLink.vaultNameKey) private var vaultName = ""

    var body: some ToolbarContent {
        #if os(macOS)
        // Secondary, as on iOS: the primary place is the inspector button's,
        // at the window's trailing edge.
        ToolbarItemGroup(placement: .secondaryAction) {
            editButton
            shareNote
            Menu {
                Button("Local Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                    openRoute(.localGraph(path: detail.path))
                }
                pinButton
                Divider()
                if let obsidianURL {
                    ShareLink(item: obsidianURL, subject: Text(detail.title)) {
                        Label("Share Link", systemImage: "link")
                    }
                }
                copyButtons
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More for this note")
        }
        #else
        ToolbarItemGroup(placement: .secondaryAction) {
            pinButton
            editButton
            shareNote
            if let obsidianURL {
                ShareLink(item: obsidianURL, subject: Text(detail.title)) {
                    Label("Share Link", systemImage: "link")
                }
            }
            copyButtons
        }
        #endif
    }

    private var obsidianURL: URL? {
        ObsidianLink.url(vault: vaultName, notePath: detail.path)
    }

    private var pinButton: some View {
        let pinned = history.isPinned(detail.path)
        return Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            history.togglePin(path: detail.path, title: detail.title)
        }
    }

    private var editButton: some View {
        Button {
            // Without a vault name there is no link yet: go set it up
            // rather than showing a disabled item that explains nothing.
            if let obsidianURL { openURL(obsidianURL) } else { app.showSettings() }
        } label: {
            Label {
                Text(obsidianURL == nil ? "Edit in Obsidian…" : "Edit in Obsidian")
                if obsidianURL == nil { Text("Set the vault name in Settings") }
            } icon: {
                Image(systemName: "square.and.pencil")
            }
        }
        .help("Edit in Obsidian (⌘E)")
    }

    private var shareNote: some View {
        ShareLink(item: NoteMarkdown(session: session, id: detail.id, title: detail.title),
                  subject: Text(detail.title), preview: SharePreview(detail.title)) {
            Label("Share Note…", systemImage: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private var copyButtons: some View {
        if let obsidianURL {
            Button("Copy Obsidian Link", systemImage: "link") {
                Pasteboard.copy(obsidianURL)
            }
        }
        Button("Copy Wikilink", systemImage: "curlybraces") {
            Pasteboard.copy("[[\(VaultPath.basename(of: detail.path))]]")
        }
        // Text selection stops at each block; this copies the whole note.
        Button("Copy Note Text", systemImage: "doc.on.doc") {
            Task {
                if let body = try? await session.notes.note(id: detail.id)?.body {
                    Pasteboard.copy(body)
                }
            }
        }
    }
}

/// A note's Markdown, read when shared: a `.md` file named after the note
/// (Mail attaches it, Finder saves it), or plain text for apps that take
/// text.
struct NoteMarkdown: Transferable {
    let session: LibrarySession
    let id: Int64
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText) { note in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share/\(note.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(note.fileName)
            try Data(await note.body().utf8).write(to: file)
            return SentTransferredFile(file)
        }
        DataRepresentation(exportedContentType: .plainText) { note in
            Data(try await note.body().utf8)
        }
    }

    /// The title without the characters a file name cannot have.
    private var fileName: String {
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (name.isEmpty ? "Note" : name) + ".md"
    }

    private func body() async throws -> String {
        guard let body = try await session.notes.note(id: id)?.body else { throw CocoaError(.fileReadNoSuchFile) }
        return body
    }
}
