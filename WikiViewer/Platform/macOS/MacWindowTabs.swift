//
//  MacWindowTabs.swift
//  WikiViewer
//
//  SwiftUI can open a window but not a tab. A request to open as a tab
//  names the window it was made from; the new window, once on screen, adds
//  itself to that window's tab group (TabJoiner). The vault windows are
//  registered (VaultWindows), so tabs and the Dock menu never pick the
//  Settings window.
//

#if os(macOS)
import AppKit
import SwiftUI
import WikiViewerKit

@MainActor
enum MacWindowTabs {
    /// `request`, marked to join the tabs of the vault window in front
    /// (not Settings, when it is the key window).
    static func asTab(_ request: WindowRequest) -> WindowRequest {
        var request = request
        request.tabbedWith = VaultWindows.front?.window.windowNumber
        return request
    }
}

/// The windows that show the vault (MacRootView), as opposed to Settings
/// and panels, each with a way to open a route in it.
@MainActor
enum VaultWindows {
    struct Entry {
        let window: NSWindow
        let open: (Route) -> Void
    }

    private static let opens = NSMapTable<NSWindow, Opener>.weakToStrongObjects()

    /// The vault window nearest the front, if any is on screen.
    static var front: Entry? {
        for window in NSApp.orderedWindows where window.isVisible {
            if let opener = opens.object(forKey: window) { return Entry(window: window, open: opener.open) }
        }
        return nil
    }

    fileprivate static func register(_ window: NSWindow, open: @escaping (Route) -> Void) {
        opens.setObject(Opener(open: open), forKey: window)
    }

    private final class Opener {
        let open: (Route) -> Void
        init(open: @escaping (Route) -> Void) { self.open = open }
    }
}

/// Registers the window it is in as a vault window that opens routes with
/// `open` (VaultWindows).
struct VaultWindowRegistration: NSViewRepresentable {
    let open: (Route) -> Void

    func makeNSView(context: Context) -> RegistrationView { RegistrationView(open: open) }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.open = open
    }

    final class RegistrationView: NSView {
        var open: (Route) -> Void {
            didSet { register() }
        }

        init(open: @escaping (Route) -> Void) {
            self.open = open
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        private func register() {
            if let window { VaultWindows.register(window, open: open) }
        }
    }
}

/// Adds the window it is in to the tab group of the window numbered
/// `parent`, once. `onDone` is called after the one attempt, joined or not:
/// a parent closed meanwhile is not looked for again, as a window restored
/// on a later launch could have that number.
struct TabJoiner: NSViewRepresentable {
    let parent: Int
    let onDone: () -> Void

    func makeNSView(context: Context) -> JoinerView {
        JoinerView(parent: parent, onDone: onDone)
    }

    func updateNSView(_ view: JoinerView, context: Context) {}

    final class JoinerView: NSView {
        let parent: Int
        let onDone: () -> Void
        private var attempted = false

        init(parent: Int, onDone: @escaping () -> Void) {
            self.parent = parent
            self.onDone = onDone
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !attempted, let window else { return }
            attempted = true
            // On the next turn: the window is still being set up.
            DispatchQueue.main.async { [parent, onDone] in
                if let parentWindow = NSApp.window(withWindowNumber: parent), parentWindow !== window {
                    parentWindow.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
                onDone()
            }
        }
    }
}
#endif

#if os(macOS)
/// Labels the window's tab and its Window menu item with `title` (the
/// document it shows) rather than the window title, which names the list
/// (SwiftUI takes it from the content column).
struct TabTitle: NSViewRepresentable {
    let title: String?

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
    }

    /// Sets the title once in a window too: a new window's view is
    /// updated before it joins one.
    final class TitleView: NSView {
        var title: String? {
            didSet { if title != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            // Without a document, nil: the tab shows the window title, and
            // follows it.
            window.tab.title = title
            // The Window menu too: every window is titled after its list
            // ("Vault"), which tells them apart no better than "Untitled".
            NSApp.changeWindowsItem(window, title: title ?? window.title, filename: false)
        }
    }
}
#endif
