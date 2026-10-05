import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

struct ChangeRepositoryTests {
    func repository() throws -> (TempDir, ChangeRepository) {
        let tmp = TempDir()
        let manifest = try makeArtifact(at: tmp.url, generation: 9) { db in
            try db.execute(sql: """
                INSERT INTO generation_log VALUES
                  (5, '2026-10-01T00:00:00Z', 1, 0, 0),
                  (7, '2026-10-03T00:00:00Z', 1, 1, 0),
                  (8, '2026-10-04T00:00:00Z', 0, 2, 1);
                INSERT INTO change_log VALUES
                  (5, 'old.md', 0, 'Old', NULL, 0),
                  (7, 'wiki/concepts/Paxos.md', 0, 'Paxos', 'concept', 1),
                  (7, 'wiki/log.md', 1, 'log', NULL, 1),
                  (8, 'wiki/concepts/Paxos.md', 1, 'Paxos', 'concept', 1),
                  (8, 'wiki/questions/Q.md', 1, 'Q', 'thesis', 1),
                  (8, 'notes/Mine.md', 2, 'Mine', NULL, 0);
                INSERT INTO log_entries(entry_key, generation, date, operation, title, body, pages) VALUES
                  ('a', 0, '2026-09-30', 'ingest-paper', 'Baseline', '', '[]'),
                  ('b', 7, '2026-10-03', 'ingest-paper', 'Raft paper', '- Summary: x', '[["Paxos","wiki/concepts/Paxos.md"]]'),
                  ('c', 8, '2026-10-04', 'thesis', 'Is Q true', '', '[["Q","wiki/questions/Q.md"]]');
                """)
        }
        let database = try ViewerDatabase(url: tmp.url.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
        return (tmp, ChangeRepository(database: database))
    }

    @Test func digestFoldsChangesPerNoteAfterAGeneration() async throws {
        let (tmp, changes) = try repository()
        defer { withExtendedLifetime(tmp) {} }
        let digest = try await changes.digest(after: 6)
        #expect(digest.changes.map(\.path) == ["notes/Mine.md", "wiki/concepts/Paxos.md", "wiki/questions/Q.md", "wiki/log.md"])
        // Added in 7, changed in 8: new to the reader.
        #expect(digest.changes.first { $0.path == "wiki/concepts/Paxos.md" }?.kind == .added)
        #expect(digest.added == 1 && digest.modified == 3 && digest.removed == 1)
        #expect(digest.entries.map(\.title) == ["Is Q true", "Raft paper"])
        #expect(digest.ingests.map(\.title) == ["Raft paper"])
        #expect(digest.concepts.map(\.title) == ["Paxos"])
        #expect(digest.theses.map(\.title) == ["Q"])
        #expect(digest.humanChanges.map(\.title) == ["Mine"])
        #expect(digest.otherClaudeChanges.isEmpty, "the log note itself is not news")
        #expect(digest.reason(for: "wiki/concepts/Paxos.md")?.title == "Raft paper")
        #expect(digest.entries.last?.pages == [LogEntry.Page(label: "Paxos", path: "wiki/concepts/Paxos.md")])

        #expect(try await changes.digest(after: 8).isEmpty)
    }

    @Test func generationsByDate() async throws {
        let (tmp, changes) = try repository()
        defer { withExtendedLifetime(tmp) {} }
        let formatter = ISO8601DateFormatter()
        #expect(try await changes.generation(before: formatter.date(from: "2026-10-02T00:00:00Z")!) == 5)
        #expect(try await changes.generation(before: formatter.date(from: "2026-09-01T00:00:00Z")!) == 0)
        #expect(try await changes.publishedDate(of: 8) == formatter.date(from: "2026-10-04T00:00:00Z"))
    }
}
