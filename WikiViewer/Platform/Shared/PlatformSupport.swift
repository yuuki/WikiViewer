//
//  PlatformSupport.swift
//  WikiViewer
//
//  The few things the feature views need that UIKit and AppKit spell
//  differently, so the views themselves stay free of #if os.
//

import SwiftUI
import WikiViewerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
}

extension Color {
    /// The window's background.
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Code blocks, embeds, attachment rows.
    static var platformSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .quaternarySystemFill)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

extension View {
    /// A small title in the navigation bar (iOS); macOS titles are always so.
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A large title at the root of a stack and small ones below it (iOS).
    func navigationTitleDisplay(large: Bool) -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(large ? .large : .inline)
        #endif
    }

    /// Presents an attachment: full screen on iOS; on macOS images open in
    /// Quick Look and other kinds in a sheet that says why there is no preview.
    func assetPresentation(item: Binding<AssetInfo?>) -> some View {
        #if os(macOS)
        modifier(MacAssetPresentation(item: item))
        #else
        fullScreenCover(item: item) { AssetViewer(asset: $0) }
        #endif
    }
}

/// Watches for system memory pressure (the iOS memory warning, or the
/// dispatch memory-pressure source on macOS) and calls `handler` on the main
/// actor. Lives as long as the app.
@MainActor
final class MemoryPressureMonitor {
    #if os(macOS)
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    #else
    private var observer: (any NSObjectProtocol)?
    #endif

    init(handler: @escaping @MainActor () -> Void) {
        #if os(macOS)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.activate()
        #else
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        #endif
    }
}

/// Opens `route`: a NavigationLink on iOS. On macOS a row of a selectable
/// list (RouteList) is a tagged row, so selecting it opens it; anywhere
/// else a button that opens it with `openRoute` (a List keeps a
/// NavigationLink's row selected after going back, and clicking that row
/// again does nothing).
struct RouteLink<Label: View>: View {
    let route: Route
    let label: Label
    @Environment(\.openRoute) private var openRoute
    @Environment(\.selectsRows) private var selectsRows
    @Environment(\.listRowSection) private var rowSection

    init(_ route: Route, @ViewBuilder label: () -> Label) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        #if os(macOS)
        if selectsRows {
            label
                .listRowFont()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .tag(ListRowTag(section: rowSection, route: route))
        } else {
            Button { openRoute(route) } label: {
                label
                    .listRowFont()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        #else
        NavigationLink(value: route) { label }
        #endif
    }
}

extension RouteLink where Label == Text {
    init(_ title: LocalizedStringKey, route: Route) {
        self.init(route) { Text(title) }
    }

    init<S: StringProtocol>(_ title: S, route: Route) {
        self.init(route) { Text(title) }
    }
}

/// A List row's identity within one section. A macOS List takes rows of
/// different sections that share an id for one row (a note that is both
/// pinned and recent; folder 3 and note 3), showing one row's content in
/// the other's place. Lists with several sections therefore qualify each id
/// by its section: `ForEach(notes, id: \.[row: "notes"])`.
struct SectionRowID<ID: Hashable>: Hashable {
    let section: String
    let id: ID
}

extension Identifiable {
    subscript(row section: String) -> SectionRowID<ID> {
        SectionRowID(section: section, id: id)
    }
}

/// The selection of the lists in a macOS window's content column. Moving
/// it with the arrow keys opens notes but not lists (a folder would replace
/// the list being browsed); a click, Return or → opens either.
@MainActor
@Observable
final class ListSelection {
    enum Input {
        /// A click on the row.
        case click
        /// The arrow keys moved the selection.
        case arrow
        /// Return or → on the selected row.
        case activate
    }

    /// The selected row's route. The window keeps it on the document it
    /// shows, so a row can be clicked again after a link inside the note
    /// moved on; in the section of the row last selected, as a note can be
    /// listed twice (Recent and its folder).
    var selected: Route? {
        get { selectedRow?.route }
        set { selectedRow = newValue.map { ListRowTag(section: section, route: $0) } }
    }
    private(set) var selectedRow: ListRowTag?
    @ObservationIgnored private var section: String?
    /// Set when a list is opened from the keyboard, so it takes focus.
    var focusesNextList = false
    /// Changed when the user selects a row, so the list takes keyboard
    /// focus. Not when the selection follows the document: a link followed
    /// in the note leaves the keyboard with the note.
    private(set) var userSelections = 0
    @ObservationIgnored var handler: (Route, Input) -> Void = { _, _ in }

    var binding: Binding<ListRowTag?> {
        Binding { self.selectedRow } set: { row in
            guard let row else { return }
            self.section = row.section
            self.userSelections += 1
            self.handler(row.route, Self.currentInput)
        }
    }

    func activate() {
        if let selected { handler(selected, .activate) }
    }

    private static var currentInput: Input {
        #if os(macOS)
        NSApp.currentEvent?.type == .keyDown ? .arrow : .click
        #else
        .click
        #endif
    }
}

/// A row of a selectable list: its route, in its section of the list.
struct ListRowTag: Hashable {
    var section: String?
    var route: Route
}

extension View {
    /// Rows of the section a route may also be listed in elsewhere in the
    /// same list (Recent and the folder's notes): only the clicked one is
    /// shown selected.
    func listRowSection(_ section: String) -> some View {
        environment(\.listRowSection, section)
    }
}

extension EnvironmentValues {
    /// The section of a selectable list the rows are in (`listRowSection`).
    @Entry var listRowSection: String?
    /// Set by the macOS content column: its lists are selectable.
    @Entry var listSelection: ListSelection?
    /// Rows of a selectable list are tagged rather than buttons.
    @Entry var selectsRows = false
}

/// A List of routes: selectable, with keyboard navigation, in a macOS
/// window's content column (ListSelection); a plain List elsewhere.
struct RouteList<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.listSelection) private var selection
    @Environment(NavigationModel.self) private var navigation
    @FocusState private var focused: Bool

    var body: some View {
        #if os(macOS)
        if let selection {
            List(selection: selection.binding) {
                content()
            }
            .environment(\.selectsRows, true)
            .focused($focused)
            // A click on a row does not give the list keyboard focus on
            // its own; without it the arrow keys do nothing.
            .onChange(of: selection.userSelections) { focused = true }
            .onKeyPress(.return) {
                selection.activate()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard selection.selected?.isList == true else { return .ignored }
                selection.activate()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard navigation.canGoBack else { return .ignored }
                selection.focusesNextList = true
                navigation.back()
                return .handled
            }
            .onAppear {
                guard selection.focusesNextList else { return }
                selection.focusesNextList = false
                focused = true
            }
        } else {
            List { content() }
        }
        #else
        List { content() }
        #endif
    }
}

#if os(macOS)
extension View {
    /// A search field above a list in the content column, where `.searchable`
    /// would put it at the far end of the window's toolbar, over the note.
    func inlineSearchField(text: Binding<String>, prompt: LocalizedStringKey,
                           focused: FocusState<Bool>.Binding? = nil,
                           onSubmit: @escaping () -> Void = {}) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            InlineSearchField(text: text, prompt: prompt, focused: focused, onSubmit: onSubmit)
        }
    }
}

private struct InlineSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let focused: FocusState<Bool>.Binding?
    let onSubmit: () -> Void
    @FocusState private var ownFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused ?? $ownFocus)
                    .onSubmit(onSubmit)
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""
                        return .handled
                    }
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: .rect(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }
}
#endif
