//
//  NoteListView.swift
//  WikiViewer
//

import SwiftUI

struct NoteListView: View {
    @State private var model: NoteListModel

    init(model: NoteListModel = NoteListModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notes")
        }
        .task {
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't Open Notes",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let notes) where notes.isEmpty:
            ContentUnavailableView("No Notes", systemImage: "note.text")
        case .loaded(let notes):
            List(notes) { note in
                Text(note.title)
            }
        }
    }
}

#Preview {
    NoteListView()
}
