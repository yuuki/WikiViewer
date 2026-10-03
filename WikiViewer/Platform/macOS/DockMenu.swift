//
//  DockMenu.swift
//  WikiViewer
//
//  The application delegate: the Dock icon's menu (the pinned and the
//  recently read notes, opened in the vault window in front, or a new one
//  when none is open), and saving the reading history on quit.
//

#if os(macOS)
import AppKit
import SwiftUI
import WikiViewerKit

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let history = DockMenu.history else { return nil }
        let menu = NSMenu()
        func add(_ entries: some Sequence<HistoryEntry>, title: String) {
            let entries = Array(entries)
            guard !entries.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for entry in entries {
                menu.addItem(actionMenuItem(verbatim: entry.title, systemImage: "doc.text") {
                    DockMenu.open(.note(path: entry.path, anchor: nil))
                })
            }
        }
        add(history.pins.prefix(DockMenu.limit), title: String(localized: "Pinned"))
        add(history.recents.prefix(DockMenu.limit), title: String(localized: "Recent"))
        return menu
    }

    /// The history saves a moment after each change, and when a window
    /// goes inactive, which ⌘Q does not reliably wait for.
    func applicationWillTerminate(_ notification: Notification) {
        DockMenu.history?.save()
    }
}

/// What the Dock menu needs from the windows.
@MainActor
enum DockMenu {
    static let limit = 8
    static var history: ReadingHistory?
    static var openWindow: OpenWindowAction?

    static func open(_ route: Route) {
        if let front = VaultWindows.front {
            front.open(route)
            front.window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(value: WindowRequest(route: route))
        }
        NSApp.activate()
    }
}
#endif
