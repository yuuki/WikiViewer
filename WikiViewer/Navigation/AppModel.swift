//
//  AppModel.swift
//  WikiViewer
//
//  App-wide UI state shared by the tabs and the keyboard commands.
//

import SwiftUI
import WikiViewerKit

struct SearchFocusRequest: Equatable {
    var id = 0
    /// Also return the search tab to its root (keyboard commands), rather
    /// than focusing only when nothing is open there (tab selection).
    var resetNavigation = false
}

@Observable
final class AppModel {
    var tab: AppTab = .files {
        didSet {
            if tab == .search, oldValue != .search {
                searchFocusRequest = SearchFocusRequest(id: searchFocusRequest.id + 1)
            }
        }
    }
    /// Set while the tab changes back to the one the window was left on,
    /// rather than to one the reader chose (macOS: the Graph section then
    /// leaves the restored documents alone).
    @ObservationIgnored var restoringTab = false

    /// Returns to the tab the window was left on.
    func restoreTab(_ saved: AppTab) {
        guard saved != tab else { return }
        restoringTab = true
        tab = saved
    }

    /// Changed to ask the search tab to focus its field.
    private(set) var searchFocusRequest = SearchFocusRequest()

    /// Switches to the search tab with the search field focused (⌘O, ⌘F).
    func showSearch() {
        tab = .search
        searchFocusRequest = SearchFocusRequest(id: searchFocusRequest.id + 1, resetNavigation: true)
    }

    /// Each tab's navigation stack, registered by the tab (iOS).
    @ObservationIgnored var navigations: [AppTab: NavigationModel] = [:]
    /// The stack documents open in, whatever the tab (macOS detail column).
    @ObservationIgnored var documentNavigation: NavigationModel?

    /// Opens a route as a link in the window would (macOS: lists in the
    /// content column, documents in the detail column), for menu commands.
    @ObservationIgnored var openHandler: ((Route) -> Void)?

    func open(_ route: Route) {
        if let openHandler { openHandler(route) } else { navigation?.push(route) }
    }

    /// The stack the Go and Note menus act on.
    var navigation: NavigationModel? { documentNavigation ?? navigations[tab] }

    /// Whether notes show the inspector (macOS).
    var showsInspector = true

    /// Only the document, without the sidebar, the list or the inspector
    /// (macOS). Leaving it brings back the columns and inspector as they
    /// were.
    var readingMode = false

    /// The Quick Open palette (⌘O on macOS).
    var showingQuickOpen = false

    /// Settings open as a sheet over whichever tab is showing.
    var showingSettings = false

    func showSettings() {
        showingSettings = true
    }
}
