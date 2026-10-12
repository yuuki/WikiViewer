//
//  ChromeTextScale.swift
//  WikiViewer
//
//  The size of the text around notes: lists, the inspector, cards and
//  status lines. iOS follows Dynamic Type. On macOS it follows System
//  Settings > Appearance > Sidebar icon size, as Finder and Mail do, and
//  never goes below 11 pt: the system's footnote and caption are 10 pt,
//  too small to read beside note text.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor @Observable
final class ChromeTextScale {
    static let shared = ChromeTextScale()

    /// Text size relative to the system's: 1 on iOS.
    private(set) var scale: CGFloat = 1

    #if os(macOS)
    private init() {
        update()
        // The setting is changed in System Settings, so it is read again
        // when the app comes back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChromeTextScale.shared.update() }
        }
    }

    private func update() {
        let next = Self.scale(sidebarSizeMode: UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode"))
        if next != scale { scale = next }
    }

    /// Small (1) and medium (2) keep the system sizes; large (3) sets body
    /// text at 15 pt, as a large sidebar does and as note text is at 100%.
    nonisolated static func scale(sidebarSizeMode: Int) -> CGFloat {
        sidebarSizeMode == 3 ? 15.0 / 13 : 1
    }
    #else
    private init() {}
    #endif
}

extension Font.TextStyle {
    /// The style text around notes is set in. macOS: footnote, caption and
    /// caption2 are all 10 pt, so they become callout (12 pt) and
    /// subheadline (11 pt), keeping footnote above caption as on iOS.
    var chrome: Font.TextStyle {
        #if os(macOS)
        switch self {
        case .footnote: .callout
        case .caption, .caption2: .subheadline
        default: self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// `style` at the size of text around notes.
    func chromeFont(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil) -> some View {
        modifier(ChromeFont(style: style, design: design, weight: weight))
    }

    /// Body text at the size of text around notes, for the text below that
    /// sets no font of its own.
    func chromeBodyFont() -> some View {
        chromeFont(.body)
    }

    /// `chromeBodyFont()` for the content of a list row. A macOS List sets
    /// each row in its own font, and a Label's title in it too, so a font
    /// set around the list, on its ForEach or on a Label does not reach
    /// the text: each row has to set it, and a Label inside its title.
    @ViewBuilder
    func listRowFont() -> some View {
        #if os(macOS)
        chromeFont(.body).labelStyle(ChromeLabelStyle())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// The system's label, its title and icon at the size of text around notes.
private struct ChromeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.chromeFont(.body)
        } icon: {
            configuration.icon.chromeFont(.body)
        }
        .labelStyle(.automatic)
    }
}
#endif

private struct ChromeFont: ViewModifier {
    let style: Font.TextStyle
    let design: Font.Design
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(NoteTextScale.font(style.chrome, design: design, weight: weight, scale: ChromeTextScale.shared.scale))
    }
}
