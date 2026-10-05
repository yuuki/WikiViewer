import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

struct NoteProvenanceTests {
    func link(_ raw: String, note: Int64?) -> OutgoingLink {
        OutgoingLink(ordinal: 0, kind: .wiki, isEmbed: false, raw: raw, targetPath: raw, heading: nil, blockID: nil,
                     display: nil, targetNoteID: note, targetAssetID: nil, line: -1)
    }

    @Test func sourcePageRestsOnItsOriginal() {
        let provenance = NoteProvenance.make(path: "wiki/sources/@2026__PVLDB__How to Write to SSDs.md", properties: [
            Property(key: "address", value: .text("c-018854")),
            Property(key: "type", value: .text("source")),
            Property(key: "updated", value: .text("2026-10-04")),
            Property(key: "status", value: .text("developing")),
            Property(key: "sources", value: .list([.text("[[.raw/papers/p1469-lee.pdf]]"), .text("[[.raw/papers/p1469-lee.txt]]")])),
            Property(key: "doi", value: .text("10.1145/3689031.3696098")),
            Property(key: "url", value: .text("https://www.vldb.org/pvldb/p1469.pdf")),
            Property(key: "publish", value: .bool(false)),
            Property(key: "author", value: .text("Bohyun Lee")),
        ], links: [link(".raw/papers/p1469-lee.pdf", note: nil)])
        #expect(provenance.author == .claude)
        #expect(provenance.verification == .unverified)
        #expect(provenance.status == "developing")
        #expect(provenance.originals.map(\.label) == ["p1469-lee.pdf", "p1469-lee.txt"])
        #expect(provenance.evidence.isEmpty)
        #expect(provenance.originalURLs.map(\.absoluteString) == ["https://www.vldb.org/pvldb/p1469.pdf", "https://doi.org/10.1145/3689031.3696098"])
        #expect(provenance.originalIsPrivate)
        #expect(provenance.updatedDate != nil)
        #expect(provenance.thesis == nil)
    }

    @Test func thesisPageCarriesItsVerdict() {
        let provenance = NoteProvenance.make(path: "wiki/questions/KV.md", properties: [
            Property(key: "type", value: .text("thesis")),
            Property(key: "thesis", value: .text("転送コストは無視できる")),
            Property(key: "verdict", value: .text("partially")),
            Property(key: "confidence", value: .text("medium")),
            Property(key: "judged", value: .text("2026-09-11")),
            Property(key: "origin", value: .text("[[KVキャッシュ管理]]")),
            Property(key: "sources", value: .list([.text("[[@2024__OSDI__DistServe]]"), .text("[[Missing|欠けた]]")])),
        ], links: [link("KVキャッシュ管理", note: 4), link("@2024__OSDI__DistServe", note: 9)])
        #expect(provenance.verification == .judged("2026-09-11"))
        #expect(provenance.thesis?.verdict == .partially)
        #expect(provenance.thesis?.statement == "転送コストは無視できる")
        #expect(provenance.thesis?.origins.map(\.noteID) == [4])
        #expect(provenance.evidence.map(\.noteID) == [9, nil])
        #expect(provenance.evidence.map(\.label) == ["@2024__OSDI__DistServe", "欠けた"])
    }

    @Test func readersNotesNeedNoVerification() {
        let human = NoteProvenance.make(path: "notes/idea.md", properties: [], links: [])
        #expect(human.author == .human)
        #expect(human.verification == .notApplicable)
        let reviewed = NoteProvenance.make(path: "wiki/concepts/A.md", properties: [Property(key: "verified", value: .bool(true))], links: [])
        #expect(reviewed.verification == .verified(nil))
        let recompiled = NoteProvenance.make(path: "wiki/concepts/A.md", properties: [Property(key: "recompiled", value: .text("2026-09-01"))], links: [])
        #expect(recompiled.verification == .recompiled("2026-09-01"))
    }
}
