import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

struct EpisodeTests {
    func link(_ raw: String, line: Int, note: Int64, heading: String? = nil) -> OutgoingLink {
        OutgoingLink(ordinal: line, kind: .wiki, isEmbed: false, raw: raw, targetPath: raw, heading: heading, blockID: nil,
                     display: nil, targetNoteID: note, targetAssetID: nil, line: line)
    }

    @Test func chaptersAreTimedLinesWithTheirNotes() {
        let body = """
        # 今日の回
        - [00:00] はじめに
        - [03:12] Alpha の要約 [[Alpha#Summary]]
        2. 1:02:03 長い話 [[Beta]]
        - 12:00 had no brackets
        - not a chapter 3:00
        """
        let chapters = EpisodeChapters.parse(body: body, links: [
            link("Alpha#Summary", line: 2, note: 1, heading: "Summary"),
            link("Beta", line: 3, note: 2),
        ])
        #expect(chapters.map(\.start) == [0, 192, 720, 3723])
        #expect(chapters.map(\.title) == ["はじめに", "Alpha の要約", "had no brackets", "長い話"])
        #expect(chapters[1].noteID == 1 && chapters[1].heading == "Summary")
        #expect(chapters[3].noteID == 2)
        #expect(EpisodeChapters.current(chapters, at: 200)?.start == 192)
        #expect(EpisodeChapters.current(chapters, at: 5000)?.start == 3723)
        #expect(EpisodeChapters.seconds("99") == nil)
    }

    @Test func recentEpisodesNewestFirst() async throws {
        let tmp = TempDir()
        let manifest = try makeArtifact(at: tmp.url, generation: 3) { db in
            try db.execute(sql: """
                INSERT INTO episodes VALUES ((SELECT id FROM notes WHERE path = 'Home.md'), NULL, '2026-10-01', 600),
                                            ((SELECT id FROM notes WHERE path = 'Projects/Alpha.md'), 1, '2026-10-04', NULL)
                """)
        }
        let database = try ViewerDatabase(url: tmp.url.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
        let episodes = try await EpisodeRepository(database: database).recent()
        #expect(episodes.map(\.note.path) == ["Projects/Alpha.md", "Home.md"])
        #expect(episodes[1].duration == 600)
    }
}
