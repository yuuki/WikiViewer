import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

@Suite struct RepositoryTests {
    let db: ViewerDatabase
    let session: LibrarySession

    init() throws {
        db = try openDemo()
        session = LibrarySession(database: db, installed: nil)
    }

    func id(_ path: String) async throws -> Int64 {
        try #require(try await session.notes.noteID(path: path))
    }

    @Test func generationInfo() {
        #expect(db.generation.generation == 1)
        #expect(db.generation.noteCount == 11)
        #expect(db.generation.schemaVersion == WikiVersions.schemaVersion)
        #expect(db.generation.createdDate != nil)
        var info = db.generation
        info.createdAt = "not a date"
        #expect(info.createdDate == nil)
    }

    @Test func databaseIsReadOnly() async throws {
        await #expect(throws: (any Error).self) {
            try await db.reader.read { db in try db.execute(sql: "DELETE FROM notes") }
        }
        // query_only is set on the connection.
        let queryOnly = try await db.reader.read { db in try Int.fetchOne(db, sql: "PRAGMA query_only") }
        #expect(queryOnly == 1)
    }

    @Test func folderBrowsingIsLazyAndPaged() async throws {
        let root = try await session.folders.subfolders(of: ViewerSchema.rootFolderID)
        #expect(root.items.map(\.name) == ["Archive", "attachments", "Café", "Daily", "Meetings", "Projects", "日本語"])
        #expect(!root.hasMore)
        var folderCursor: FolderSummary?
        var folderNames: [String] = []
        while true {
            let page = try await session.folders.subfolders(of: ViewerSchema.rootFolderID, after: folderCursor, limit: 2)
            folderNames += page.items.map(\.name)
            folderCursor = page.items.last
            if !page.hasMore { break }
        }
        #expect(folderNames == root.items.map(\.name))
        let rootNotes = try await session.folders.notes(in: ViewerSchema.rootFolderID)
        #expect(rootNotes.items.map(\.title) == ["Code", "Empty", "Home", "Invalid YAML"])

        // Keyset pagination: 1 per page walks the folder in title order.
        var cursor: TitleCursor?
        var titles: [String] = []
        repeat {
            let page = try await session.folders.notes(in: ViewerSchema.rootFolderID, after: cursor, limit: 1)
            titles += page.items.map(\.title)
            cursor = page.items.last.map(TitleCursor.init(after:))
            if !page.hasMore { break }
        } while true
        #expect(titles == ["Code", "Empty", "Home", "Invalid YAML"])

        // Every order pages with a keyset cursor to the same list as one page.
        func walk(_ order: NoteOrder) async throws -> [String] {
            var cursor: NoteCursor?
            var titles: [String] = []
            while true {
                let page = try await session.folders.notes(in: ViewerSchema.rootFolderID, order: order, after: cursor, limit: 1)
                titles += page.items.map(\.title)
                cursor = page.items.last.map(NoteCursor.init(after:))
                if !page.hasMore { break }
            }
            return titles
        }
        #expect(try await walk(.titleAscending) == ["Code", "Empty", "Home", "Invalid YAML"])
        #expect(try await walk(.titleDescending) == ["Invalid YAML", "Home", "Empty", "Code"])
        let byModified = try await db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM notes WHERE folder_id = 1 ORDER BY mtime_ns DESC, id DESC")
        }
        #expect(try await walk(.modifiedNewest) == byModified)
        let newest = try await session.folders.notes(in: ViewerSchema.rootFolderID, order: .modifiedNewest)
        #expect(newest.items.allSatisfy { $0.modified != nil })
        #expect(FolderRepository.canSortByModified(noteCount: FolderRepository.maxNotesSortedByModified))
        #expect(!FolderRepository.canSortByModified(noteCount: FolderRepository.maxNotesSortedByModified + 1))

        let archive = try #require(root.items.first { $0.name == "Archive" })
        #expect(archive.folderCount == 1)
        let attachments = try #require(root.items.first { $0.name == "attachments" })
        let assets = try await session.folders.assets(in: attachments.id)
        #expect(assets.items.map(\.name) == ["copy of diagram.png", "diagram.png", "photo.jpg"])
    }

    @Test func noteDetailAndProperties() async throws {
        let home = try #require(try await session.notes.note(id: try await id("Home.md")))
        #expect(home.title == "Home")
        #expect(home.body.hasPrefix("# Home"))
        #expect(home.properties.map(\.key) == ["aliases", "tags", "created", "rating", "draft"])
        #expect(home.properties[0].value == .list([.text("Start"), .text("ホーム")]))
        #expect(home.properties[3].value == .number("5"))
        #expect(home.properties[4].value == .bool(false))
        let prefix = try await session.notes.bodyPrefix(id: home.id, maxCharacters: 6)
        #expect(prefix == "# Home")
        #expect(try await session.notes.notes(basename: "meeting notes").map(\.path) == ["Archive/2024/Meeting Notes.md", "Meetings/Meeting Notes.md"])
    }

    @Test func backlinks() async throws {
        let home = try await id("Home.md")
        let page = try await session.links.backlinks(to: home)
        #expect(page.items.map(\.note.path).sorted() == ["Code.md", "Projects/Alpha.md", "日本語/東京メモ.md"])
        #expect(try await session.links.backlinkCount(to: home) == 3)
        let beta = try await id("Projects/Beta.md")
        let betaBacklinks = try await session.links.backlinks(to: beta)
        let fromHome = try #require(betaBacklinks.items.first { $0.note.path == "Home.md" })
        #expect(fromHome.linkCount == 3, "[[Beta#Goals]], [[Beta#^decision-1]], [Beta as markdown](Projects/Beta.md)")
        // Context: the line holding the first link, lines counted after frontmatter.
        #expect(try await session.links.backlinkContext(from: try await id("Projects/Alpha.md"), to: home)
                == "Alpha is the first project. It links back to [[Home]] and to [[Beta]].")
        #expect(try await session.links.backlinkContext(from: try await id("Code.md"), to: home) == "Real link after code: [[Home]]")
        #expect(try await session.links.backlinkContext(from: home, to: try await id("Code.md")) == nil, "no such link")
        let missing = try await session.links.notesLinkingToMissing("Nonexistent Note")
        #expect(missing.map(\.path) == ["Home.md"])
    }

    @Test func backlinkKeysetPaging() async throws {
        let home = try await id("Home.md")
        var cursor: Int64?
        var seen: [String] = []
        repeat {
            let page = try await session.links.backlinks(to: home, before: cursor, limit: 1)
            seen += page.items.map(\.note.path)
            cursor = page.items.last?.id
            if !page.hasMore { break }
        } while true
        #expect(seen.sorted() == ["Code.md", "Projects/Alpha.md", "日本語/東京メモ.md"])
        #expect(Set(seen).count == seen.count, "no duplicates across pages")
        #expect(try await session.links.backlinkCount(to: home, cap: 2) == 2, "count is capped")
    }

    @Test func tagKeysetPaging() async throws {
        let project = try #require(try await session.tags.tag(named: "PROJECT"))
        var cursor: Int64?
        var seen: [String] = []
        repeat {
            let page = try await session.tags.notes(taggedWith: project, includeNested: true, before: cursor, limit: 1)
            seen += page.items.map(\.path)
            cursor = page.items.last?.id
            if !page.hasMore { break }
        } while true
        #expect(seen.sorted() == ["Projects/Alpha.md", "Projects/Beta.md"])
    }

    @Test func outgoingLinksAndHeadings() async throws {
        let home = try await id("Home.md")
        let links = try await session.links.outgoingLinks(of: home)
        #expect(links.map(\.ordinal) == Array(0..<links.count))
        let unresolved = links.filter { !$0.isResolved }.map(\.raw)
        #expect(unresolved == ["Nonexistent Note"])
        let beta = try await id("Projects/Beta.md")
        let headings = try await session.links.headings(of: beta)
        #expect(headings.map(\.text) == ["Beta", "Goals", "決定事項"])
        #expect(try await session.links.blockLine(noteID: beta, blockID: "decision-1") == 9)
    }

    @Test func tags() async throws {
        let all = try await session.tags.tags()
        #expect(all.items.map(\.name).contains("日本語"))
        let project = try #require(try await session.tags.tag(named: "project"))
        let nested = try await session.tags.notes(taggedWith: project, includeNested: true)
        #expect(nested.items.map(\.path).sorted() == ["Projects/Alpha.md", "Projects/Beta.md"], "project/beta is nested under project")
        let flat = try await session.tags.notes(taggedWith: project, includeNested: false)
        #expect(flat.items.map(\.path) == ["Projects/Alpha.md"])
        let prefixed = try await session.tags.tags(prefix: "proj")
        #expect(prefixed.items.map(\.name) == ["project", "project/alpha", "project/beta"])
        let homeTags = try await session.tags.tags(of: try await id("Home.md"))
        #expect(homeTags.map(\.name) == ["index", "inline-tag", "日本語"])
    }

    @Test func assets() async throws {
        let home = try await id("Home.md")
        let links = try await session.links.outgoingLinks(of: home)
        let photoLink = try #require(links.first { $0.raw == "photo.jpg|400" })
        let photoID = try #require(photoLink.targetAssetID)
        let photo = try #require(try await session.assets.asset(id: photoID))
        #expect(photo.kind == .image)
        #expect(photo.width == 1365 && photo.height == 2048)
        #expect(photo.blobRelativePath?.hasPrefix("assets/") == true)
    }
}

@Suite struct SearchTests {
    let search: any SearchEngine

    init() throws {
        search = TrigramSearchEngine(database: try openDemo())
    }

    @Test func japaneseFullText() async throws {
        let hits = try await search.search("東京都", limit: 10)
        #expect(hits.map(\.note.path) == ["日本語/東京メモ.md"])
        let snippet = try #require(hits.first?.snippet)
        #expect(snippet.contains("\u{02}東京都\u{03}"), "highlight markers around the match")
        #expect(try await search.search("全文検索", limit: 10).map(\.note.path) == ["日本語/東京メモ.md"])
        #expect(try await search.search("データベースの性能", limit: 10).map(\.note.path) == ["日本語/東京メモ.md"])
    }

    @Test func snippetHighlightsWholeMultiTrigramMatch() async throws {
        let hits = try await search.search("Trigram", limit: 10)
        let snippet = try #require(hits.first?.snippet)
        #expect(snippet.contains("\u{02}trigram\u{03}"), "snippet: \(snippet.debugDescription)")
    }

    @Test func englishAndMultipleTerms() async throws {
        #expect(try await search.search("trigram tokenizer", limit: 10).map(\.note.path) == ["Projects/Beta.md"])
        #expect(try await search.search("TRIGRAM", limit: 10).map(\.note.path) == ["Projects/Beta.md"])
        #expect(try await search.search("trigram nonexistentword", limit: 10).isEmpty)
    }

    @Test func mixedShortAndLongTerms() async throws {
        // "天気" is 2 characters: applied as a LIKE filter on the FTS hits.
        #expect(try await search.search("東京都 天気", limit: 10).map(\.note.path) == ["日本語/東京メモ.md"])
        #expect(try await search.search("東京都 犬猫", limit: 10).isEmpty)
    }

    @Test func shortQueryFallbackUsesNamesAndTags() async throws {
        // Two characters: titles/aliases/tags only.
        let hits = try await search.search("東京", limit: 10)
        #expect(hits.map(\.note.path) == ["日本語/東京メモ.md"])
        #expect(hits.first?.match == .title)
        let tagHits = try await search.search("日本", limit: 10)
        #expect(Set(tagHits.map(\.note.path)).isSuperset(of: ["日本語/東京メモ.md", "Home.md"]))
    }

    @Test func reportsWhetherNoteTextIsSearched() {
        #expect(!TrigramSearchEngine.searchesNoteText("東京"))
        #expect(!TrigramSearchEngine.searchesNoteText("東京 天気"))
        #expect(!TrigramSearchEngine.searchesNoteText("  "))
        #expect(TrigramSearchEngine.searchesNoteText("東京都"))
        #expect(TrigramSearchEngine.searchesNoteText("東京 東京都"))
        #expect(TrigramSearchEngine.searchesNoteText("alpha"))
    }

    @Test func quickSwitcher() async throws {
        #expect(try await search.quickSwitch("hom", limit: 10).first?.note.path == "Home.md")
        #expect(try await search.quickSwitch("HOME", limit: 10).first?.note.path == "Home.md")
        let alias = try await search.quickSwitch("ホー", limit: 10)
        #expect(alias.first?.note.path == "Home.md")
        #expect(alias.first?.match == .alias("ホーム"))
        let infix = try await search.quickSwitch("eeting", limit: 10)
        #expect(infix.map(\.note.path).sorted() == ["Archive/2024/Meeting Notes.md", "Meetings/Meeting Notes.md"])
        #expect(try await search.quickSwitch("", limit: 10).isEmpty)
        #expect(try await search.quickSwitch("%", limit: 10).isEmpty, "LIKE wildcards are escaped")
    }

    @Test func maliciousQueriesAreSafe() async throws {
        for q in ["\"", "\"\"\"", "a\" OR \"b", "NEAR(", "*", "^", "title:x", "); DROP TABLE notes; --"] {
            _ = try await search.search(q, limit: 10)
            _ = try await search.quickSwitch(q, limit: 10)
        }
    }
}
