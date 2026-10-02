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

/// Opens `route` in the current tab: a NavigationLink on iOS. On macOS a
/// List keeps a NavigationLink's row selected after going back, and clicking
/// that row again does nothing; a button pushes on every click.
struct RouteLink<Label: View>: View {
    let route: Route
    let label: Label
    @Environment(NavigationModel.self) private var navigation

    init(_ route: Route, @ViewBuilder label: () -> Label) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        #if os(macOS)
        Button { navigation.push(route) } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
