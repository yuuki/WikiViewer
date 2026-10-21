//
//  RecallView.swift
//  WikiViewer
//
//  Recall practice (#40): questions about notes read a few days ago, asked
//  again at growing intervals. The questions come with the snapshot; the
//  schedule (RecallCard per question), the daily limits and what was
//  discarded stay on this device.
//

import SwiftUI
import WikiShared
import WikiViewerKit

@MainActor
@Observable
final class RecallStore {
    struct Stored: Codable {
        var cards: [String: RecallCard] = [:]
        var day = ""
        var newToday = 0
        var reviewsToday = 0
        var newLimit = 10
        var reviewLimit = 40
    }

    private(set) var stored: Stored
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = RecallStore.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WikiViewer", isDirectory: true).appendingPathComponent("recall.json")
    }

    var newLimit: Int {
        get { stored.newLimit }
        set { stored.newLimit = max(0, newValue); save() }
    }

    var reviewLimit: Int {
        get { stored.reviewLimit }
        set { stored.reviewLimit = max(0, newValue); save() }
    }

    private static func dayString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    /// Resets the daily counts on a new day.
    private func rollDay(_ now: Date) {
        let today = Self.dayString(now)
        if stored.day != today {
            stored.day = today
            stored.newToday = 0
            stored.reviewsToday = 0
        }
    }

    func queue(_ items: [RecallItem], now: Date = .now) -> [RecallItem] {
        let today = Self.dayString(now)
        let fresh = stored.day != today
        return RecallQueue.today(items: items, cards: stored.cards, now: now, newLimit: stored.newLimit, reviewLimit: stored.reviewLimit,
                                 newDoneToday: fresh ? 0 : stored.newToday, reviewsDoneToday: fresh ? 0 : stored.reviewsToday)
    }

    func answer(_ item: RecallItem, _ grade: RecallCard.Grade, now: Date = .now) {
        rollDay(now)
        if let card = stored.cards[item.id] {
            stored.cards[item.id] = card.reviewed(grade, at: now)
            stored.reviewsToday += 1
        } else {
            stored.cards[item.id] = RecallCard.first(grade, at: now)
            stored.newToday += 1
        }
        save()
    }

    /// Never asks the question again.
    func discard(_ item: RecallItem, now: Date = .now) {
        var card = stored.cards[item.id] ?? RecallCard.first(.good, at: now)
        card.suspended = true
        stored.cards[item.id] = card
        save()
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: fileURL, options: .atomic) }
    }
}

struct RecallView: View {
    @Environment(Library.self) private var library
    @Environment(RecallStore.self) private var store
    @Environment(\.openRoute) private var openRoute
    @State private var items: [RecallItem] = []
    @State private var queue: [RecallItem] = []
    @State private var showsAnswer = false
    @State private var loaded = false

    var body: some View {
        content
            .navigationTitle("Recall")
            .inlineNavigationTitle()
            .toolbar {
                Menu {
                    Stepper("New per Day: \(store.newLimit)", value: Bindable(store).newLimit, in: 0...50)
                    Stepper("Reviews per Day: \(store.reviewLimit)", value: Bindable(store).reviewLimit, in: 0...200, step: 5)
                    if let current = queue.first {
                        Divider()
                        Button("Discard This Question", systemImage: "trash") {
                            store.discard(current)
                            advance()
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            .task(id: library.session?.id) {
                items = (try? await library.session?.recall.items()) ?? []
                queue = store.queue(items)
                loaded = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let item = queue.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(queue.count) left today").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.note.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(item.question).font(.title3.weight(.semibold)).textSelection(.enabled)
                    }
                    if showsAnswer {
                        Divider()
                        Text(item.answer).font(.body).textSelection(.enabled)
                        Button {
                            openRoute(.note(path: item.note.path, anchor: item.heading.map { NoteAnchor(heading: $0) }))
                        } label: {
                            Label(item.heading.map { String(localized: "Open “\($0)”") } ?? String(localized: "Open Note"), systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                        gradeButtons(item)
                    } else {
                        Button("Show Answer") { withAnimation(.snappy) { showsAnswer = true } }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else if loaded {
            ContentUnavailableView("Nothing to Recall", systemImage: "brain",
                                   description: Text(items.isEmpty
                                       ? "Questions about notes you read a few days ago appear here once your Mac makes them (scripts/make-recall.py)."
                                       : "You are done for today."))
        } else {
            ProgressView()
        }
    }

    private func gradeButtons(_ item: RecallItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How well did you remember?").font(.caption).foregroundStyle(.secondary)
            HStack {
                grade("Forgot", .again, item, tint: .red)
                grade("Hard", .hard, item, tint: .orange)
                grade("Good", .good, item, tint: .green)
                grade("Easy", .easy, item, tint: .blue)
            }
        }
    }

    private func grade(_ title: LocalizedStringKey, _ grade: RecallCard.Grade, _ item: RecallItem, tint: Color) -> some View {
        Button {
            store.answer(item, grade)
            advance()
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func advance() {
        showsAnswer = false
        queue = store.queue(items)
    }
}
