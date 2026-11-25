//
//  LinkHoverPreview.swift
//  WikiViewer
//
//  ⌘ over a link in a note's text shows the linked note in a popover, as
//  Obsidian's page preview does (over a footnote reference, the footnote),
//  and a right-click on a link offers to open it in a new tab or window,
//  edit it in Obsidian or copy it. The link under the pointer is found with
//  LinkRunLayout.
//

#if os(macOS)
import AppKit
import SwiftUI
import WikiShared
import WikiViewerKit

extension View {
    /// ⌘-hover previews for the links of a Text built with `markingLinks`.
    func linkHoverPreviews() -> some View {
        modifier(LinkHoverPreview())
    }
}

private struct LinkHoverPreview: ViewModifier {
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    @Environment(\.openRoute) private var openRoute
    @Environment(\.footnoteDefinitions) private var footnotes
    @State private var layout = LinkRunLayout()
    @State private var hovered: (url: URL, rect: CGRect)?
    @State private var preview: Preview?
    @State private var monitor: Any?
    @State private var hold: Task<Void, Never>?

    struct Preview {
        var content: Content
        var rect: CGRect

        enum Content {
            case note(path: String, title: String)
            case footnote([RenderBlock])
        }
    }

    func body(content: Content) -> some View {
        content
            .textRenderer(LinkRunRecorder(layout: layout))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let link = layout.link(at: point)
                    if link?.url != hovered?.url { preview = nil }
                    hovered = link
                    if link != nil { watchCommandKey() }
                    update()
                case .ended:
                    hovered = nil
                    preview = nil
                    stopWatching()
                }
            }
            .popover(isPresented: Binding { preview != nil } set: { if !$0 { dismissed() } },
                     attachmentAnchor: .rect(.rect(preview?.rect ?? .zero)), arrowEdge: .bottom) {
                switch preview?.content {
                case .note(let path, let title):
                    NotePreviewCard(path: path, title: title, session: library.session)
                case .footnote(let blocks):
                    FootnoteCard(blocks: blocks) { preview = nil }
                case nil:
                    EmptyView()
                }
            }
            .onDisappear(perform: stopWatching)
    }

    /// Shows the hovered link's note once ⌘ is down; it stays until the
    /// pointer leaves the link.
    private func update() {
        guard let hovered, preview == nil, CommandHold.isCommandAlone else { return cancelHold() }
        guard hold == nil else { return }
        let rect = hovered.rect
        let url = hovered.url
        if let footnote = footnotes?.definition(for: url) {
            hold = Task {
                try? await Task.sleep(for: CommandHold.delay)
                if Task.isCancelled { return }
                hold = nil
                guard self.hovered?.url == url, CommandHold.isCommandAlone else { return }
                preview = Preview(content: .footnote(footnote), rect: rect)
            }
            return
        }
        guard case .note(let id, _, _) = WikiLinkAction(url: url), let session = library.session else { return }
        hold = Task {
            try? await Task.sleep(for: CommandHold.delay)
            if Task.isCancelled { return }
            hold = nil
            guard self.hovered?.url == url, CommandHold.isCommandAlone,
                  let note = try? await session.notes.summary(id: id), self.hovered?.url == url else { return }
            preview = Preview(content: .note(path: note.path, title: note.title), rect: rect)
        }
    }

    private func cancelHold() {
        hold?.cancel()
        hold = nil
    }

    /// The popover takes a click outside it only to close itself, so a
    /// ⌘-click on the link it previews would do nothing: open the link
    /// here (the click's ⌘ still picks a new tab).
    private func dismissed() {
        preview = nil
        if NSApp.currentEvent?.type == .leftMouseDown, let hovered { openURL(hovered.url) }
    }

    /// ⌘ pressed or released, or a right-click, over a link.
    private func watchCommandKey() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .rightMouseDown]) { event in
            // ⌘ held for a shortcut (⌘O, ⌘[): no preview.
            if event.type == .keyDown {
                cancelHold()
                return event
            }
            guard event.type == .rightMouseDown else {
                update()
                return event
            }
            // The link's menu instead of the text's (Copy, Look Up…).
            guard let hovered, let view = event.window?.contentView else { return event }
            preview = nil
            let menu = LinkMenu.menu(for: hovered.url, session: library.session, openURL: openURL, openRoute: openRoute)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// ⌘ held alone for a moment brings up a preview; ⌘ pressed on the way to
/// a shortcut, or with another modifier, does not.
@MainActor
enum CommandHold {
    static let delay: Duration = .milliseconds(350)

    static var isCommandAlone: Bool {
        NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }
}

/// The context menu of a link in a note's text.
@MainActor
enum LinkMenu {
    static func menu(for url: URL, session: LibrarySession?, openURL: OpenURLAction, openRoute: OpenRouteAction) -> NSMenu {
        let menu = NSMenu()
        guard let action = WikiLinkAction(url: url) else { return menu }
        let vault = UserDefaults.standard.string(forKey: ObsidianLink.vaultNameKey) ?? ""

        /// Resolves the link to a route when chosen: a note link names the
        /// note by id.
        func open(in target: RouteTarget) {
            switch action {
            case .note(let id, let heading, let blockID):
                Task {
                    guard let note = try? await session?.notes.summary(id: id) else { return }
                    let anchor = heading != nil || blockID != nil ? NoteAnchor(heading: heading, blockID: blockID) : nil
                    openRoute(.note(path: note.path, anchor: anchor), in: target)
                }
            case .missing(let name): openRoute(.missing(target: name), in: target)
            case .tag(let name): openRoute(.tag(name: name), in: target)
            case .asset, .external: openURL(url)
            }
        }

        menu.addItem(actionMenuItem("Open", systemImage: "doc.text") { open(in: .automatic) })
        switch action {
        case .note, .missing, .tag:
            menu.addItem(actionMenuItem("Open in New Tab", systemImage: "plus.square.on.square") { open(in: .newTab) })
            menu.addItem(actionMenuItem("Open in New Window", systemImage: "macwindow.badge.plus") { open(in: .newWindow) })
        case .asset, .external:
            break
        }
        menu.addItem(.separator())
        switch action {
        case .note(let id, let heading, _):
            if !vault.trimmingCharacters(in: .whitespaces).isEmpty {
                menu.addItem(actionMenuItem("Edit in Obsidian", systemImage: "square.and.pencil") {
                    Task {
                        guard let note = try? await session?.notes.summary(id: id),
                              let link = ObsidianLink.url(vault: vault, notePath: note.path) else { return }
                        openURL(link)
                    }
                })
            }
            menu.addItem(actionMenuItem("Copy Wikilink", systemImage: "curlybraces") {
                Task {
                    guard let note = try? await session?.notes.summary(id: id) else { return }
                    let name = VaultPath.basename(of: note.path)
                    Pasteboard.copy("[[\(heading.map { name + "#" + $0 } ?? name)]]")
                }
            })
        case .missing(let name):
            menu.addItem(actionMenuItem("Copy Wikilink", systemImage: "curlybraces") { Pasteboard.copy("[[\(name)]]") })
        case .tag(let name):
            menu.addItem(actionMenuItem("Copy Tag", systemImage: "number") { Pasteboard.copy("#" + name) })
        case .external(let link):
            menu.addItem(actionMenuItem("Copy Link", systemImage: "link") { Pasteboard.copy(link) })
        case .asset:
            break
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
func actionMenuItem(_ title: String.LocalizationValue, systemImage: String, handler: @escaping () -> Void) -> NSMenuItem {
    actionMenuItem(verbatim: String(localized: title), systemImage: systemImage, handler: handler)
}

/// A menu item titled with text that is not localized (a note's title).
@MainActor
func actionMenuItem(verbatim title: String, systemImage: String, handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler: handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    // The item holds its target only weakly.
    item.representedObject = action
    item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    return item
}

private final class MenuAction: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
#endif
