//
//  AppCommands.swift
//  WikiViewer
//
//  The menu bar (macOS) and keyboard shortcuts (iPad, macOS). Commands act
//  on the focused window through its AppModel, a focused scene value, and
//  through it on the visible tab: its navigation stack and the note on top.
//

import SwiftUI
import WikiShared
import WikiViewerKit

/// The note on top of a tab, for the Note menu.
struct NoteFocus {
    var detail: NoteDetail
    var session: LibrarySession
    var openURL: OpenURLAction
}

extension FocusedValues {
    @Entry var appModel: AppModel?
}

struct AppCommands: Commands {
    let startup: LibraryStartup
    let history: ReadingHistory
    @FocusedValue(\.appModel) private var app
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private var navigation: NavigationModel? { app?.navigation }
    private var note: NoteFocus? { navigation?.note }

    var body: some Commands {
        #if os(macOS)
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button(app?.showsInspector == false ? "Show Inspector" : "Hide Inspector") {
                app?.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(app == nil)
        }
        #endif

        CommandGroup(after: .newItem) {
            #if os(macOS)
            Button("New Tab") {
                openWindow(value: MacWindowTabs.asTab(WindowRequest()))
            }
            .keyboardShortcut("t", modifiers: .command)
            Divider()
            #endif
            Button("Search Notes") { app?.showSearch() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(app == nil)
            Button("Find in Vault") { app?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app == nil)
            Divider()
            Button("Check for New Snapshot") {
                Task { await startup.library?.checkForUpdates() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(startup.library?.source == nil)
        }

        CommandMenu("Go") {
            Button("Back") { navigation?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(navigation?.canGoBack ?? false))
            Button("Forward") { navigation?.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(navigation?.canGoForward ?? false))
            Divider()
            tabButton("Files", .files, key: "1")
            tabButton("Tags", .tags, key: "2")
            tabButton("Graph", .graph, key: "3")
            tabButton("Search", .search, key: "4")
        }

        CommandMenu("Note") {
            let detail = note?.detail
            Button("Edit in Obsidian") { editInObsidian() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(detail == nil)
            if let detail, history.isPinned(detail.path) {
                Button("Unpin") { history.togglePin(path: detail.path, title: detail.title) }
                    .keyboardShortcut("d", modifiers: .command)
            } else {
                Button("Pin") {
                    if let detail { history.togglePin(path: detail.path, title: detail.title) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(detail == nil)
            }
            Button("Local Graph") {
                if let detail { navigation?.push(.localGraph(path: detail.path)) }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(detail == nil || navigation == nil)
            Divider()
            Button("Copy Wikilink") {
                if let detail { Pasteboard.copy("[[\(VaultPath.basename(of: detail.path))]]") }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(detail == nil)
            Button("Copy Obsidian Link") {
                if let url = obsidianURL { Pasteboard.copy(url) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(obsidianURL == nil)
            Button("Copy Note Text") {
                guard let note else { return }
                Task {
                    if let body = try? await note.session.notes.note(id: note.detail.id)?.body {
                        Pasteboard.copy(body)
                    }
                }
            }
            .disabled(detail == nil)
        }
    }

    private func tabButton(_ title: LocalizedStringKey, _ tab: AppTab, key: KeyEquivalent) -> some View {
        Button(title) { app?.tab = tab }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(app == nil)
    }

    private var obsidianURL: URL? {
        guard let detail = note?.detail else { return nil }
        let vault = UserDefaults.standard.string(forKey: ObsidianLink.vaultNameKey) ?? ""
        return ObsidianLink.url(vault: vault, notePath: detail.path)
    }

    /// Without a vault name there is no link yet: go set it up instead.
    private func editInObsidian() {
        if let url = obsidianURL {
            note?.openURL(url)
        } else {
            app?.showSettings()
        }
    }
}
