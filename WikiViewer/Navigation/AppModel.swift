//
//  AppModel.swift
//  WikiViewer
//
//  App-wide UI state shared by the tabs and the keyboard commands.
//

import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case files, search, tags, graph
}

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

    /// The stack the Go and Note menus act on.
    var navigation: NavigationModel? { documentNavigation ?? navigations[tab] }

    /// Whether notes show the inspector (macOS).
    var showsInspector = true

    /// Settings open as a sheet over whichever tab is showing.
    var showingSettings = false

    func showSettings() {
        showingSettings = true
    }
}
