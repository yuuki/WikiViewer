//
//  AudioPlayer.swift
//  WikiViewer
//
//  Listening to review (#43): one player for the app. It plays a recording
//  published with the snapshot (fetched like an image, verified against
//  its digest, kept for offline), remembers where each recording was left,
//  keeps playing in the background, answers the lock screen and earphone
//  controls, and knows which chapter — which note — is playing.
//

import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import WikiShared
import WikiViewerKit

@MainActor
@Observable
final class AudioPlayer {
    struct Item: Equatable {
        var asset: AssetInfo
        var title: String
        /// The episode note, if the recording is one.
        var notePath: String?
        var chapters: [EpisodeChapter]
    }

    enum Phase: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    private(set) var item: Item?
    private(set) var phase: Phase = .idle
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            if isPlaying { player?.rate = rate }
            updateNowPlaying()
        }
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let skip: Double = 15
    static let rateKey = "WikiViewer.audio.rate"
    static let positionsKey = "WikiViewer.audio.positions"

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastSaved = Date.distantPast

    static let shared = AudioPlayer()

    init() {
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(saved) ? saved : 1
        configureRemoteCommands()
    }

    var currentChapter: EpisodeChapter? {
        guard let item else { return nil }
        return EpisodeChapters.current(item.chapters, at: currentTime)
    }

    // MARK: Positions

    /// Seconds where each recording (by digest) was left.
    static func savedPosition(_ sha256: String?) -> Double? {
        guard let sha256 else { return nil }
        return (UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double])?[sha256]
    }

    private func savePosition(force: Bool = false) {
        guard let sha = item?.asset.blobSHA256, force || Date.now.timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = .now
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        // Finished (or nearly): start over next time.
        positions[sha] = duration > 0 && currentTime > duration - 10 ? nil : currentTime
        if positions.count > 200 { positions = Dictionary(uniqueKeysWithValues: positions.prefix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    // MARK: Playing

    /// Loads (fetching the recording if needed) and plays from where it was left.
    func play(_ item: Item, library: Library, at start: Double? = nil) async {
        if self.item == item, phase == .ready {
            if let start { seek(to: start) }
            resume()
            return
        }
        stop()
        self.item = item
        phase = .loading
        do {
            let url = try await library.blobURL(for: item.asset)
            guard self.item == item else { return }
            let player = AVPlayer(url: url)
            self.player = player
            player.automaticallyWaitsToMinimizeStalling = false
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time) }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPlaying = false
                    self?.savePosition(force: true)
                    self?.updateNowPlaying()
                }
            }
            if let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
            phase = .ready
            let from = start ?? Self.savedPosition(item.asset.blobSHA256) ?? 0
            if from > 0 { await player.seek(to: CMTime(seconds: from, preferredTimescale: 600)) }
            currentTime = from
            activateSession()
            resume()
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(String(localized: "The recording could not be fetched. Connect to your Mac's folder or address, or download it while online."))
        }
    }

    func resume() {
        guard let player else { return }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        savePosition(force: true)
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        savePosition(force: true)
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func stop() {
        savePosition(force: true)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        item = nil
        phase = .idle
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func tick(_ time: CMTime) {
        guard time.seconds.isFinite else { return }
        let chapter = currentChapter
        currentTime = time.seconds
        savePosition()
        if chapter != currentChapter { updateNowPlaying() }
    }

    private func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: Lock screen and earphones

    private func updateNowPlaying() {
        guard let item else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? item.title,
            MPMediaItemPropertyAlbumTitle: item.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        info[MPMediaItemPropertyArtist] = "WikiViewer"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skip)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: Self.skip) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skip)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -Self.skip) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
        // Chapters: next/previous track jump between topics.
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(1) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(-1) }
            return .success
        }
    }

    func jumpChapter(_ offset: Int) {
        guard let chapters = item?.chapters, !chapters.isEmpty else { return skip(by: Double(offset) * Self.skip) }
        let index = chapters.lastIndex { $0.start <= currentTime + 0.5 } ?? -1
        let target = min(max(index + offset, 0), chapters.count - 1)
        seek(to: chapters[target].start)
    }
}

/// "12:34" or "1:02:03".
func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
