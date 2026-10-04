//
//  EpisodeViews.swift
//  WikiViewer
//
//  The player's faces (#43): the card at the top of an episode note (or
//  under an embedded recording), with its chapters — each the topic of a
//  note, so the reader can go from what is playing to where it is
//  written — and the "Listen" section of the home list.
//

import SwiftUI
import WikiShared
import WikiViewerKit

struct PlayerCard: View {
    let item: AudioPlayer.Item
    /// Opens a chapter's note.
    var onOpenChapter: ((EpisodeChapter) -> Void)?
    @Environment(Library.self) private var library
    @State private var player = AudioPlayer.shared
    @State private var scrubbing: Double?
    @State private var downloaded = false

    private var isCurrent: Bool { player.item == item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(item.title, systemImage: "headphones").font(.headline).lineLimit(2)
                Spacer()
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Available offline"))
                }
            }
            if isCurrent, case .failed(let message) = player.phase {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            controls
            if !item.chapters.isEmpty {
                chapters
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .task(id: item.asset.blobSHA256) {
            downloaded = item.asset.blobSHA256.flatMap { sha in item.asset.blobExt.flatMap { library.assetProvider.localURL(sha256: sha, ext: $0) } }
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    @ViewBuilder
    private var controls: some View {
        let time = isCurrent ? (scrubbing ?? player.currentTime) : (AudioPlayer.savedPosition(item.asset.blobSHA256) ?? 0)
        let duration = isCurrent ? player.duration : 0
        VStack(spacing: 4) {
            if duration > 0 {
                Slider(value: Binding(get: { time }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                    if !editing, let scrubbing {
                        player.seek(to: scrubbing)
                        self.scrubbing = nil
                    }
                }
                HStack {
                    Text(formatPlaybackTime(time))
                    Spacer()
                    Text("-" + formatPlaybackTime(max(0, duration - time)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if time > 0 {
                Text("Resumes at \(formatPlaybackTime(time))").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                Button { player.skip(by: -AudioPlayer.skip) } label: { Image(systemName: "gobackward.15") }
                    .disabled(!isCurrent)
                    .accessibilityLabel(Text("Back 15 seconds"))
                Button {
                    if isCurrent, player.phase == .ready { player.toggle() } else { Task { await player.play(item, library: library) } }
                } label: {
                    if isCurrent, player.phase == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                    }
                }
                .accessibilityLabel(isCurrent && player.isPlaying ? Text("Pause") : Text("Play"))
                Button { player.skip(by: AudioPlayer.skip) } label: { Image(systemName: "goforward.15") }
                    .disabled(!isCurrent)
                    .accessibilityLabel(Text("Forward 15 seconds"))
                Menu {
                    Picker("Speed", selection: Bindable(player).rate) {
                        ForEach(AudioPlayer.rates, id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                    }
                } label: {
                    Text(String(format: "%.2g×", player.rate)).font(.callout.monospacedDigit())
                }
                .accessibilityLabel(Text("Playback Speed"))
                if !downloaded {
                    Button {
                        Task {
                            _ = try? await library.blobURL(for: item.asset)
                            downloaded = true
                        }
                    } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel(Text("Download for Offline"))
                }
            }
            .font(.title2)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(item.chapters) { chapter in
                let playing = isCurrent && player.currentChapter == chapter
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        if isCurrent, player.phase == .ready { player.seek(to: chapter.start); player.resume() } else {
                            Task { await player.play(item, library: library, at: chapter.start) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatPlaybackTime(chapter.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(chapter.title).font(.subheadline.weight(playing ? .semibold : .regular)).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if chapter.noteID != nil, let onOpenChapter {
                        Button { onOpenChapter(chapter) } label: { Image(systemName: "doc.text") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Open the note"))
                    }
                }
                .padding(.vertical, 6)
                .foregroundStyle(playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
        }
    }
}

/// The home list's "Listen": what is playing, episodes left half-way,
/// and the newest ones.
struct ListenHomeSection: View {
    let episodes: [EpisodeSummary]
    @State private var player = AudioPlayer.shared

    var body: some View {
        if player.item != nil || !episodes.isEmpty {
            Section("Listen") {
                if let item = player.item {
                    HStack {
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentChapter?.title ?? item.title).lineLimit(1)
                            Text("\(formatPlaybackTime(player.currentTime)) / \(formatPlaybackTime(player.duration))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let path = item.notePath {
                            Spacer()
                            RouteLink(Route.note(path: path, anchor: nil)) { Image(systemName: "chevron.forward") }
                                .accessibilityLabel(Text("Open the episode"))
                        }
                    }
                }
                ForEach(episodes, id: \.[row: "episodes"]) { episode in
                    RouteLink(Route.note(path: episode.note.path, anchor: nil)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.note.title).lineLimit(2)
                                Text(episode.published + (episode.duration.map { " · " + formatPlaybackTime(Double($0)) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "headphones")
                        }
                    }
                }
            }
            .listRowSection("listen")
        }
    }
}
