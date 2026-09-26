import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct FrontmatterLinkTests {
    @Test func wikilinksInPropertyValuesAreLinks() {
        let text = """
        ---
        up: "[[Home]]"
        related: ["[[Alpha|the alpha]]", "plain", "[[Beta#Goals]]"]
        nested:
          source: "see [[Gamma]] and [text](Delta.md)"
        count: 3
        ---
        Body [[Epsilon]]
        """
        let parsed = NoteParser.parse(path: "Note.md", text: text)
        #expect(parsed.links.map(\.raw) == ["Epsilon", "Home", "Alpha|the alpha", "Beta#Goals", "Gamma"],
                "body links first, then frontmatter wikilinks; Markdown links in properties are text")
        #expect(parsed.links.map(\.line) == [0, -1, -1, -1, -1])
    }

    @Test func frontmatterLinksAreResolved() async throws {
        let env = try Env(copyFixture: true)
        try env.write("Linked.md", "---\nup: \"[[Home]]\"\nrelated:\n  - \"[[Projects/Beta]]\"\n---\n# Linked\n\n[[Alpha]]\n")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Linked.md", ordinal: 0) == "Projects/Alpha.md")
            #expect(try linkTarget(db, from: "Linked.md", ordinal: 1) == "Home.md")
            #expect(try linkTarget(db, from: "Linked.md", ordinal: 2) == "Projects/Beta.md")
        }
    }

    @Test func parserChangeReparsesUnchangedNotes() async throws {
        let env = try Env(copyFixture: true)
        try env.write("Linked.md", "---\nup: \"[[Home]]\"\n---\n# Linked\n")
        do {
            let indexer = try Indexer(configuration: env.config)
            _ = try await indexer.reconcile()
        }
        // Simulate a builder written by the previous parser, which ignored
        // frontmatter links.
        let builder = try BuilderDatabase(url: env.config.builderDatabaseURL)
        try await builder.writer.write { db in
            try db.execute(sql: "DELETE FROM links WHERE line = -1")
            try db.execute(sql: "UPDATE builder_state SET value = '1' WHERE key = 'parser_version'")
        }
        try builder.writer.close()

        let indexer = try Indexer(configuration: env.config)
        let stats = try await indexer.reconcile()
        #expect(stats.index.notesWritten == 12)
        #expect(stats.index.assetsWritten == 0, "assets are not reprocessed")
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Linked.md", raw: "Home") == "Home.md")
        }
        #expect(try await indexer.reconcile().candidates == 0)
    }
}
