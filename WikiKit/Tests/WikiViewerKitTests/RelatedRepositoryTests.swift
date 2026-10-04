import Foundation
import GRDB
import Testing
import WikiShared
@testable import WikiViewerKit

struct RelatedRepositoryTests {
    @Test func neighboursAreGroupedByRoleInOrder() async throws {
        let tmp = TempDir()
        let manifest = try makeArtifact(at: tmp.url, generation: 3) { db in
            func id(_ path: String) throws -> Int64 { try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE path = ?", arguments: [path])! }
            let home = try id("Home.md")
            try db.execute(sql: "INSERT INTO related VALUES (?, 'cluster', 0, ?, NULL)", arguments: [home, try id("Code.md")])
            try db.execute(sql: "INSERT INTO related VALUES (?, 'definition', 1, ?, NULL)", arguments: [home, try id("Projects/Beta.md")])
            try db.execute(sql: "INSERT INTO related VALUES (?, 'definition', 0, ?, '接続')", arguments: [home, try id("Projects/Alpha.md")])
            try db.execute(sql: "INSERT INTO related VALUES (?, 'analogy', 0, ?, NULL)", arguments: [home, try id("Code.md")])
        }
        let database = try ViewerDatabase(url: tmp.url.appendingPathComponent(manifest.database.path), options: .init(immutable: true))
        let notes = NoteRepository(database: database)
        let repository = RelatedRepository(database: database)
        let home = try #require(try await notes.noteID(path: "Home.md"))
        let groups = try await repository.related(to: home)
        #expect(groups.map(\.role) == ["definition", "cluster", "analogy"])
        #expect(groups[0].items.map(\.note.path) == ["Projects/Alpha.md", "Projects/Beta.md"])
        #expect(groups[0].items[0].why == "接続")
        let alpha = try #require(try await notes.noteID(path: "Projects/Alpha.md"))
        #expect(try await repository.related(to: alpha).isEmpty)
    }
}
