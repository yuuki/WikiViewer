//
//  HostRequest.swift
//  WikiShared
//
//  The one way data flows from a device back to the Mac: a request the app
//  puts in a queue outside the vault (`<publish>/inbox/`, or POST /requests
//  to `wikiindex serve`). `wikiindex requests` on the Mac takes each one,
//  hands it to Claude Code running in the vault (or, for reading signals,
//  stores it outside the vault), and reports progress as a status file the
//  app reads back (`<publish>/requests/<id>.json`). The answer itself is a
//  note Claude writes into the vault, which reaches the device with the
//  next snapshot like any other note.
//
//  Neither the app nor wikiindex writes to the vault: the request is data,
//  and the only writer is the vault's own Claude session, confined by the
//  runner to `wiki/` (see THREAT_MODEL.md).
//

import Foundation

public struct HostRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A question about a note or some of its paragraphs. The answer is
        /// a note under `wiki/` (wiki-ask-source, or wiki-thesis for "is
        /// this true?").
        case ask
        /// A learning path for a subject: existing notes in prerequisite
        /// order (#35).
        case path
        /// The reader's own explanation of a note, checked against it (#41).
        case explain
        /// A two-voice audio episode about a note (#44).
        case podcast
        /// Reading history, dwell times and pins (#42). Stored on the Mac
        /// outside the vault; never passed to Claude as a prompt.
        case signals
    }

    /// The canned questions of an `ask`. `free` uses `text` alone.
    public enum Question: String, Codable, Sendable, CaseIterable {
        /// "Is this true?" — judged by wiki-thesis.
        case verify
        /// "What does this assume?"
        case premise
        /// "What would contradict it?"
        case counterexample
        case free
    }

    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    /// The device's name, shown on the Mac (e.g. "iPhone").
    public var device: String?
    /// Vault path of the note the request is about.
    public var notePath: String?
    public var noteTitle: String?
    /// The heading the selected paragraphs are under.
    public var heading: String?
    /// The selected paragraphs, as plain text.
    public var excerpt: String?
    public var question: Question?
    /// Free text: the question, the subject of a path, or the explanation.
    public var text: String?
    public var signals: [ReadingSignal]?

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date(), device: String? = nil,
                notePath: String? = nil, noteTitle: String? = nil, heading: String? = nil, excerpt: String? = nil,
                question: Question? = nil, text: String? = nil, signals: [ReadingSignal]? = nil) {
        version = Self.currentVersion
        self.id = id
        self.kind = kind
        // Whole seconds: what ISO 8601 in JSON keeps.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.device = device
        self.notePath = notePath
        self.noteTitle = noteTitle
        self.heading = heading
        self.excerpt = excerpt
        self.question = question
        self.text = text
        self.signals = signals
    }

    // MARK: Limits

    /// Largest encoded request either side accepts.
    public static let maximumEncodedSize = 512 * 1024
    public static let maximumTextLength = 16_000
    public static let maximumSignals = 5_000

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedVersion(Int)
        case tooLarge(String)
        case unsafePath(String)
        case missing(String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let v): "unsupported request version \(v)"
            case .tooLarge(let field): "\(field) is too long"
            case .unsafePath(let p): "unsafe note path \(p)"
            case .missing(let field): "\(field) is required"
            }
        }
    }

    /// Checks what a request must carry for its kind and that nothing is
    /// oversized. Both the app (before queueing) and the Mac (before acting)
    /// call it.
    public func validate() throws(ValidationError) {
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        for (name, value) in [("text", text), ("excerpt", excerpt), ("heading", heading), ("noteTitle", noteTitle), ("device", device)] {
            if let value, value.count > Self.maximumTextLength { throw .tooLarge(name) }
        }
        if let notePath {
            guard VaultPath.isSafeRelative(notePath), !notePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                throw .unsafePath(notePath)
            }
        }
        let hasText = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .ask:
            guard notePath != nil else { throw .missing("notePath") }
            guard question != nil else { throw .missing("question") }
            if question == .free, !hasText { throw .missing("text") }
        case .path:
            guard hasText else { throw .missing("text") }
        case .explain:
            guard notePath != nil else { throw .missing("notePath") }
            guard hasText else { throw .missing("text") }
        case .podcast:
            guard notePath != nil || hasText else { throw .missing("notePath") }
        case .signals:
            guard let signals else { throw .missing("signals") }
            guard signals.count <= Self.maximumSignals else { throw .tooLarge("signals") }
            for signal in signals {
                guard VaultPath.isSafeRelative(signal.path) else { throw .unsafePath(signal.path) }
                if signal.title.count > 1_000 { throw .tooLarge("signals") }
            }
        }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func encoded() throws -> Data {
        let data = try Self.encoder.encode(self)
        guard data.count <= Self.maximumEncodedSize else { throw ValidationError.tooLarge("request") }
        return data
    }

    /// Decodes and validates untrusted bytes.
    public static func decode(_ data: Data) throws -> HostRequest {
        guard data.count <= maximumEncodedSize else { throw ValidationError.tooLarge("request") }
        let request = try decoder.decode(HostRequest.self, from: data)
        try request.validate()
        return request
    }

    /// The queue file name: `<uuid>.json`, the only names either side reads.
    public var fileName: String { Self.fileName(for: id) }

    public static func fileName(for id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    /// The id in a queue or status file name, or nil for any other name.
    public static func id(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".json"), name.count == 41 else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }
}

/// One note read on a device (#42).
public struct ReadingSignal: Codable, Sendable, Equatable {
    public var path: String
    public var title: String
    public var openedAt: Date
    /// Time on screen, in seconds (0 when unknown).
    public var seconds: Int
    /// The furthest top-level block reached, if the note was scrolled.
    public var block: Int?
    public var pinned: Bool

    public init(path: String, title: String, openedAt: Date, seconds: Int, block: Int? = nil, pinned: Bool = false) {
        self.path = path
        self.title = title
        self.openedAt = openedAt
        self.seconds = seconds
        self.block = block
        self.pinned = pinned
    }
}

/// Progress of a request, written by the Mac to
/// `<publish>/requests/<id>.json` and read by the app.
public struct HostRequestStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// In the queue on the Mac.
        case queued
        /// Claude is working on it.
        case processing
        case done
        case failed

        public var isFinal: Bool { self == .done || self == .failed }
    }

    /// A point the Mac found in the reader's explanation (#41).
    public struct Finding: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// Something the note says that the explanation left out.
            case missing
            /// Something the explanation gets wrong.
            case misconception
        }

        public var kind: Kind
        public var text: String
        /// The heading of the note the point is about.
        public var heading: String?

        public init(kind: Kind, text: String, heading: String? = nil) {
            self.kind = kind
            self.text = text
            self.heading = heading
        }
    }

    public var id: UUID
    public var kind: HostRequest.Kind
    public var state: State
    public var updatedAt: Date
    /// A short human-readable note: what was done, or why it failed.
    public var message: String?
    /// Vault path of the note written in answer, once done.
    public var answerPath: String?
    public var findings: [Finding]?

    public init(id: UUID, kind: HostRequest.Kind, state: State, updatedAt: Date = Date(), message: String? = nil,
                answerPath: String? = nil, findings: [Finding]? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.updatedAt = updatedAt
        self.message = message
        self.answerPath = answerPath
        self.findings = findings
    }

    public static let maximumEncodedSize = 256 * 1024

    public static func decode(_ data: Data) throws -> HostRequestStatus {
        guard data.count <= maximumEncodedSize else { throw HostRequest.ValidationError.tooLarge("status") }
        let status = try HostRequest.decoder.decode(HostRequestStatus.self, from: data)
        if let answerPath = status.answerPath, !VaultPath.isSafeRelative(answerPath) {
            throw HostRequest.ValidationError.unsafePath(answerPath)
        }
        return status
    }

    /// Published path of a request's status file.
    public static func publishedPath(for id: UUID) -> String { "requests/" + HostRequest.fileName(for: id) }
}
