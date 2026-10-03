//
//  DockMenu.swift
//  WikiViewer
//
//  The Dock icon's menu: the pinned and the recently read notes, opened in
//  the window last in front (or a new one when none is open).
//

#if os(macOS)
import AppKit
import SwiftUI
import WikiViewerKit

@MainActor
final class DockMenuDelegate: NSObject, NSApplicationDelegate {
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
}

/// What the Dock menu needs from the windows, which register as they
/// come to the front.
@MainActor
enum DockMenu {
    static let limit = 8
    static var history: ReadingHistory?
    /// Opens a route in the window last in front.
    static var openInWindow: ((Route) -> Void)?
    static var openWindow: OpenWindowAction?

    static func open(_ route: Route) {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if hasWindow, let openInWindow {
            openInWindow(route)
        } else {
            openWindow?(value: WindowRequest(route: route))
        }
        NSApp.activate()
    }
}
#endif
