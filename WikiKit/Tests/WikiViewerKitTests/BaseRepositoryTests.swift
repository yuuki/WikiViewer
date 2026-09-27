import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

/// Fixtures/vault/Notes.base, as evaluated into the demo artifact.
@Suite struct BaseRepositoryTests {
    let session: LibrarySession

    init() throws {
        session = LibrarySession(database: try openDemo(), installed: nil)
    }

    @Test func baseDefinitionIsRead() async throws {
        let base = try #require(try await session.bases.base(path: "Notes.base"))
        #expect(base.name == "Notes")
        #expect(base.document.error == nil)
        #expect(base.document.views.map(\.name) == ["By folder", "Tagged", "Name"])
        #expect(base.document.views.map(\.type) == ["table", "table", "list"])
        #expect(base.document.views[0].columns.first?.isFileName == true)
        #expect(try await session.bases.base(path: "Home.md") == nil)
        #expect(try await session.bases.base(path: "Missing.base") == nil)
    }

    @Test func groupedViewPagesInGroupOrder() async throws {
        let base = try #require(try await session.bases.base(path: "Notes.base"))
        let groups = try await session.bases.groups(baseID: base.assetID, view: 0)
        #expect(groups.map(\.label) == ["Café", "Daily", "Meetings", "Projects", "日本語", nil])
        #expect(groups.map(\.rowCount).reduce(0, +) == base.document.views[0].rowCount)

        // Pages of 3 along the keyset give every row once, in order.
        var rows: [BaseRow] = []
        var cursor: BaseCursor?
        repeat {
            let page = try await session.bases.rows(baseID: base.assetID, view: 0, after: cursor, limit: 3)
            rows += page.items
            cursor = page.hasMore ? page.items.last.map(BaseCursor.init(after:)) : nil
        } while cursor != nil
        #expect(rows.count == base.document.views[0].rowCount)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.first?.name == "Ünïcode Nöte")
        // Rows arrive grouped: each group key appears in one run.
        var runs: [Data] = []
        for row in rows where runs.last != row.groupKey { runs.append(row.groupKey) }
        #expect(runs == groups.map(\.key))
    }

    @Test func cellsAreDecoded() async throws {
        let base = try #require(try await session.bases.base(path: "Notes.base"))
        let page = try await session.bases.rows(baseID: base.assetID, view: 1, limit: 50)
        let home = try #require(page.items.first { $0.note.path == "Home.md" })
        #expect(home.cells["rating"] == .number(5))
        #expect(home.cells["formula.tag_list"]?.displayText == "日本語, inline-tag")
    }
}

@Suite struct BaseCellTests {
    @Test func compactJSONRoundTrips() throws {
        let cells: [String: BaseCell] = [
            "t": .text("x"), "n": .number(2.5), "b": .bool(true), "d": .date("2026-09-27"),
            "l": .link(display: "Alpha", path: "Projects/Alpha.md"), "u": .link(display: "Missing", path: nil),
            "list": .list([.text("a"), .number(1)]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(cells), as: UTF8.self)
        #expect(json == #"{"b":true,"d":{"d":"2026-09-27"},"l":{"l":"Alpha","p":"Projects\/Alpha.md"},"list":["a",1],"n":2.5,"t":"x","u":{"l":"Missing"}}"#)
        #expect(try JSONDecoder().decode([String: BaseCell].self, from: Data(json.utf8)) == cells)
    }

    @Test func displayText() {
        #expect(BaseCell.number(3).displayText == "3")
        #expect(BaseCell.number(0.5).displayText == "0.5")
        #expect(BaseCell.list([.text("a"), .link(display: "B", path: nil)]).displayText == "a, B")
        #expect(BaseDocument.Column(id: "formula.topic_tags", displayName: nil).label == "topic_tags")
        #expect(BaseDocument.Column(id: "status", displayName: "成熟度").label == "成熟度")
    }
}
