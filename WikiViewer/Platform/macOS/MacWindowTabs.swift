//
//  MacWindowTabs.swift
//  WikiViewer
//
//  SwiftUI can open a window but not a tab. A request to open as a tab
//  names the window it was made from; the new window, once on screen, adds
//  itself to that window's tab group (TabJoiner).
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
enum MacWindowTabs {
    /// `request`, marked to join the key window's tabs.
    static func asTab(_ request: WindowRequest) -> WindowRequest {
        var request = request
        request.tabbedWith = NSApp.keyWindow?.windowNumber
        return request
    }
}

/// Adds the window it is in to the tab group of the window numbered
/// `parent`, once.
struct TabJoiner: NSViewRepresentable {
    let parent: Int
    let onJoined: () -> Void

    func makeNSView(context: Context) -> JoinerView {
        JoinerView(parent: parent, onJoined: onJoined)
    }

    func updateNSView(_ view: JoinerView, context: Context) {}

    final class JoinerView: NSView {
        let parent: Int
        let onJoined: () -> Void
        private var joined = false

        init(parent: Int, onJoined: @escaping () -> Void) {
            self.parent = parent
            self.onJoined = onJoined
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !joined, let window, let parentWindow = NSApp.window(withWindowNumber: parent),
                  parentWindow !== window else { return }
            joined = true
            // On the next turn: the window is still being set up.
            DispatchQueue.main.async { [onJoined] in
                parentWindow.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
                onJoined()
            }
        }
    }
}
#endif

#if os(macOS)
/// Labels the window's tab with `title` (the document it shows) rather than
/// the window title, which names the list (SwiftUI takes it from the
/// content column).
struct TabTitle: NSViewRepresentable {
    let title: String?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let title = title
        // The view may join its window after this update.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tab.title = title ?? window.title
        }
    }
}
#endif
