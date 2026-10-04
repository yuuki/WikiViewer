//
//  NoteProvenance.swift
//  WikiViewerKit
//
//  Where a note comes from (#37): who wrote it (Provenance), how far it has
//  been checked, how fresh it is, and what it rests on — its `sources`
//  (wiki pages, or for a source page the original under `.raw/`, which is
//  never in the snapshot) and the original's address online. A thesis page
//  (wiki-thesis) adds its verdict.
//
//  Everything comes from the note's frontmatter and its link rows, so it
//  costs no query beyond loading the note.
//

import Foundation
import WikiShared

public struct NoteProvenance: Sendable, Equatable {
    public enum Verification: Sendable, Equatable {
        /// Written by the reader: nothing to verify.
        case notApplicable
        /// Written by Claude, not checked yet.
        case unverified
        /// Marked checked (`verified` / `reviewed`), with the date if given.
        case verified(String?)
        /// A concept recompiled against its sources (`recompiled`).
        case recompiled(String)
        /// A thesis judged against the wiki's sources (`judged`).
        case judged(String)
    }

    /// Something the note rests on.
    public struct Reference: Sendable, Equatable, Identifiable {
        public var target: String
        public var label: String
        /// The note in the snapshot, if the reference resolves to one.
        public var noteID: Int64?
        /// An original under `.raw/` (not published to the device).
        public var isOriginal: Bool

        public var id: String { target }
    }

    public struct Thesis: Sendable, Equatable {
        public enum Verdict: String, Sendable, CaseIterable {
            case supported, partially, contradicted, insufficient, mixed
        }

        public var statement: String?
        public var question: String?
        public var verdict: Verdict?
        public var verdictText: String?
        public var confidence: String?
        public var judged: String?
        public var origins: [Reference]
    }

    public var author: Provenance.Author
    public var status: String?
    public var verification: Verification
    /// The `updated` date as written (`YYYY-MM-DD`).
    public var updated: String?
    public var sources: [Reference]
    /// The original online: `url`, or the DOI / arXiv address.
    public var originalURLs: [URL]
    /// `publish: false`: the original is not to be shared (e.g. a book).
    public var originalIsPrivate: Bool
    public var thesis: Thesis?

    public var originals: [Reference] { sources.filter(\.isOriginal) }
    public var evidence: [Reference] { sources.filter { !$0.isOriginal } }

    /// The parsed `updated` date.
    public var updatedDate: Date? {
        guard let updated else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(updated.prefix(10)))
    }

    public static func make(path: String, properties: [Property], links: [OutgoingLink]) -> NoteProvenance {
        var byRaw: [String: OutgoingLink] = [:]
        for link in links where link.kind == .wiki && byRaw[link.raw] == nil {
            byRaw[link.raw] = link
        }
        var fields: [String: String] = [:]
        var values: [String: PropertyValue] = [:]
        for property in properties {
            values[property.key] = property.value
            switch property.value {
            case .text(let s), .number(let s): fields[property.key] = s
            case .bool(let b): fields[property.key] = b ? "true" : "false"
            default: break
            }
        }
        let author = Provenance.author(path: path, fields: fields)
        func references(_ key: String) -> [Reference] {
            texts(values[key]).compactMap { reference($0, byRaw: byRaw) }
        }

        var verification: Verification = author == .human ? .notApplicable : .unverified
        if let judged = fields["judged"] {
            verification = .judged(judged)
        } else if let verified = fields["verified"] ?? fields["reviewed"], verified.lowercased() != "false" {
            verification = .verified(verified.lowercased() == "true" ? nil : verified)
        } else if let recompiled = fields["recompiled"] {
            verification = .recompiled(recompiled)
        }

        var urls: [URL] = []
        if let url = fields["url"].flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            urls.append(url)
        }
        if let doi = fields["doi"], !doi.isEmpty, let url = URL(string: "https://doi.org/" + doi) { urls.append(url) }
        if let arxiv = fields["arxiv_id"], !arxiv.isEmpty, let url = URL(string: "https://arxiv.org/abs/" + arxiv), !urls.contains(url) {
            urls.append(url)
        }

        var thesis: Thesis?
        if fields["type"]?.lowercased() == "thesis" || fields["verdict"] != nil {
            thesis = Thesis(statement: fields["thesis"], question: fields["question"],
                            verdict: fields["verdict"].flatMap { Thesis.Verdict(rawValue: $0.lowercased()) },
                            verdictText: fields["verdict"], confidence: fields["confidence"], judged: fields["judged"],
                            origins: references("origin"))
        }

        return NoteProvenance(author: author, status: fields["status"], verification: verification, updated: fields["updated"],
                              sources: references("sources"), originalURLs: urls,
                              originalIsPrivate: fields["publish"]?.lowercased() == "false", thesis: thesis)
    }

    /// The strings of a property value (a list's items).
    static func texts(_ value: PropertyValue?) -> [String] {
        switch value {
        case .text(let s)?: [s]
        case .list(let items)?: items.flatMap { texts($0) }
        default: []
        }
    }

    /// "[[target|label]]" (or a bare name) as a reference.
    static func reference(_ text: String, byRaw: [String: OutgoingLink]) -> Reference? {
        var inner = text.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[["), inner.hasSuffix("]]") { inner = String(inner.dropFirst(2).dropLast(2)) }
        guard !inner.isEmpty else { return nil }
        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        let page = target.split(separator: "#").first.map(String.init) ?? target
        let label = parts.count > 1 ? parts[1] : (page.split(separator: "/").last.map(String.init) ?? page)
        let isOriginal = page.hasPrefix(".raw/") || page.hasPrefix("raw/")
        return Reference(target: target, label: label, noteID: byRaw[target]?.targetNoteID, isOriginal: isOriginal)
    }
}
