//
//  NoteSpeech.swift
//  WikiViewer
//
//  Edit > Speech on macOS. The system's Start Speaking reads a text view's
//  selection, and notes are SwiftUI text, so the app replaces it with one
//  that reads the note: its visible text, without code and math, in a
//  voice for the language it is written in.
//

#if os(macOS)
import AVFoundation
import NaturalLanguage
import WikiViewerKit

@MainActor
@Observable
final class NoteSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = NoteSpeech()

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(title: String, note: RenderedNote) {
        stop()
        var parts = NoteView.startsWithTitleHeading(note, title: title) ? [] : [title]
        for block in note.blocks {
            switch block.kind {
            case .code, .math: continue
            default: parts.append(block.plainText)
            }
        }
        let text = parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }
}
#endif
