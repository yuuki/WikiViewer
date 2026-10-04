import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

struct LearningPathTests {
    func link(_ raw: String, line: Int, note: Int64?, heading: String? = nil, embed: Bool = false) -> OutgoingLink {
        OutgoingLink(ordinal: line, kind: .wiki, isEmbed: embed, raw: raw, targetPath: raw, heading: heading, blockID: nil,
                     display: nil, targetNoteID: note, targetAssetID: nil, line: line)
    }

    @Test func stepsAreTopLevelNumberedItemsWithTheirFirstResolvedLink() throws {
        let body = """
        # 学習経路: 分散合意
        ## 経路
        1. [[Paxos]] — 合意の基本形
           - 補足: [[Raft]] も参照
        2. [[Missing]] では足りないので [[Raft#Leader election]] — 実装寄り
        3) 橋渡し: ビザンチン障害 — 入門の文献が無い
        10. **[[Flexible Paxos|柔軟な Paxos]]** を最後に
        ```
        4. code is not a step
        ```
        - 5. not numbered
        """
        let links = [
            link("Paxos", line: 2, note: 1),
            link("Raft", line: 3, note: 2),
            link("Missing", line: 4, note: nil),
            link("Raft#Leader election", line: 4, note: 2, heading: "Leader election"),
            link("Flexible Paxos", line: 6, note: 3),
        ]
        let path = try #require(LearningPath.parse(body: body, links: links))
        #expect(path.steps.map(\.number) == [1, 2, 3, 10])
        #expect(path.steps.map(\.noteID) == [1, 2, nil, 3])
        #expect(path.steps[1].heading == "Leader election")
        #expect(path.steps[2].isGap)
        #expect(path.steps[0].text == "Paxos — 合意の基本形")
        #expect(path.steps[3].text == "柔軟な Paxos を最後に")
        #expect(path.steps.map(\.detail) == ["合意の基本形", "Missing では足りないので — 実装寄り", "ビザンチン障害 — 入門の文献が無い", "を最後に"])
    }

    @Test func crlfLinesCountLikeTheScanner() throws {
        let body = "intro\r\n1. [[A]]\r\n2. [[B]]\r\n"
        let path = try #require(LearningPath.parse(body: body, links: [link("A", line: 1, note: 7), link("B", line: 2, note: 8)]))
        #expect(path.steps.map(\.noteID) == [7, 8])
        #expect(path.steps.map(\.text) == ["A", "B"])
    }

    @Test func onlyPathNotesArePaths() {
        #expect(LearningPath.isPath(properties: [Property(key: "type", value: .text("path"))]))
        #expect(LearningPath.isPath(properties: [Property(key: "type", value: .text("Learning-Path"))]))
        #expect(!LearningPath.isPath(properties: [Property(key: "type", value: .text("concept"))]))
        #expect(!LearningPath.isPath(properties: []))
        #expect(LearningPath.parse(body: "no list here", links: []) == nil)
    }

    @Test func linkLinesMatchTheBody() async throws {
        let database = try openDemo()
        let notes = NoteRepository(database: database)
        let links = LinkRepository(database: database)
        let id = try #require(try await notes.noteID(path: "Projects/Alpha.md"))
        let body = try #require(try await notes.note(id: id)?.body)
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        let outgoing = try await links.outgoingLinks(of: id).filter { $0.line >= 0 }
        #expect(!outgoing.isEmpty)
        for link in outgoing {
            #expect(lines[link.line].contains(link.raw), "\(link.raw) on line \(link.line)")
        }
    }
}
