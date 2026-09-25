//
//  WikiViewerApp.swift
//  WikiViewer
//
//  Created by Yuuki Tsubouchi on 2026/09/24.
//

import SwiftUI
import WikiViewerKit

@main
struct WikiViewerApp: App {
    @State private var library: Library?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let library {
                    ContentView()
                        .environment(library)
                        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                            library.imageCache.removeAll()
                        }
                } else if let startupError {
                    ContentUnavailableView("Can't Start", systemImage: "exclamationmark.triangle", description: Text(startupError))
                } else {
                    ProgressView()
                }
            }
            .task {
                guard library == nil else { return }
                do {
                    let store = try GenerationStore(root: try GenerationStore.defaultRoot())
                    let library = Library(store: store)
                    self.library = library
                    await library.bootstrap()
                } catch {
                    startupError = error.localizedDescription
                }
            }
        }
    }
}
