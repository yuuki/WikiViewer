//
//  NoteActions.swift
//  WikiViewer
//
//  What can be done with a note besides reading it: the way back to
//  Obsidian for editing, sharing and copying.
//

import SwiftUI
import UIKit
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

/// The note's "More" toolbar items (they collect in the overflow menu).
struct NoteActionItems: ToolbarContent {
    let detail: NoteDetail
    let session: LibrarySession
    @Environment(ReadingHistory.self) private var history
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @AppStorage(ObsidianLink.vaultNameKey) private var vaultName = ""

    var body: some ToolbarContent {
        let obsidianURL = ObsidianLink.url(vault: vaultName, notePath: detail.path)
        ToolbarItemGroup(placement: .secondaryAction) {
            let pinned = history.isPinned(detail.path)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                history.togglePin(path: detail.path, title: detail.title)
            }
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
            if let obsidianURL {
                ShareLink(item: obsidianURL, subject: Text(detail.title)) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                Button("Copy Obsidian Link", systemImage: "link") {
                    UIPasteboard.general.url = obsidianURL
                }
            }
            Button("Copy Wikilink", systemImage: "curlybraces") {
                UIPasteboard.general.string = "[[\(VaultPath.basename(of: detail.path))]]"
            }
            // Text selection stops at each block; this copies the whole note.
            Button("Copy Note Text", systemImage: "doc.on.doc") {
                Task {
                    if let body = try? await session.notes.note(id: detail.id)?.body {
                        UIPasteboard.general.string = body
                    }
                }
            }
        }
    }
}
