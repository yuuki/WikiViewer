import Foundation
import GRDB
import Testing
@testable import IndexerCore
import WikiShared

@Suite struct BaseExpressionTests {
    func note(_ path: String = "wiki/concepts/Idea.md", properties: [(String, BaseValue)] = [], tags: [String] = [], mtimeNs: Int64 = 0) -> BaseNote {
        BaseNote(id: 1, path: path, mtimeNs: mtimeNs, size: 10, properties: properties, tags: { tags }, links: { [] }, backlinks: { [] })
    }

    func eval(_ source: String, _ note: BaseNote, formulas: [String: String] = [:]) throws -> BaseValue {
        let evaluator = BaseEvaluator(formulas: try formulas.mapValues(BaseExpressionParser.parse))
        evaluator.begin(note)
        return evaluator.evaluate(try BaseExpressionParser.parse(source), locals: [:])
    }

    @Test func filtersFromARealVault() throws {
        let n = note(properties: [("type", .string("concept"))])
        #expect(try eval(#"file.inFolder("wiki/concepts")"#, n).isTruthy)
        #expect(try eval(#"file.inFolder("wiki")"#, n).isTruthy, "subfolders are in the folder")
        #expect(try !eval(#"file.inFolder("wiki/con")"#, n).isTruthy)
        #expect(try eval(#"file.ext == "md""#, n).isTruthy)
        #expect(try eval(#"type == "concept""#, n).isTruthy)
        #expect(try eval(#"file.basename != "_index""#, n).isTruthy)
        #expect(try !eval(#"type == "concept" && file.basename == "_index""#, n).isTruthy)
    }

    @Test func topicTagsFormula() throws {
        // concepts.base in the author's vault.
        let formula = ##"file.tags.map(value.replace("#", "")).filter(!/^\d{4}[\/-]\d{2}[\/-]\d{2}$/.matches(value) && value != "concept")"##
        let n = note(tags: ["2026/09/26", "concept", "aiops", "log-analysis"])
        #expect(try eval(formula, n).displayString == "aiops, log-analysis")
    }

    @Test func conditionalsAndDates() throws {
        let formula = #"if(updated, date(updated), "")"#
        #expect(try eval(formula, note(properties: [("updated", .string("2026-09-26"))])).displayString == "2026-09-26")
        #expect(try eval(formula, note()).displayString == "")
        #expect(try eval(#"date("2026-09-26 16:54").format("YYYY/MM/DD HH:mm")"#, note()).displayString == "2026/09/26 16:54")
        #expect(try eval(#"(date("2026-09-26") + "1d").format("D")"#, note()).displayString == "27")
    }

    @Test func operatorsAndMethods() throws {
        let n = note(properties: [("rating", .number(4)), ("aliases", .list([.string("A"), .string("B")]))])
        #expect(try eval("rating * 2 + 1 > 8", n).isTruthy)
        #expect(try eval("-rating < 0 || false", n).isTruthy)
        #expect(try eval(#"aliases.contains("B") && aliases.length == 2"#, n).isTruthy)
        #expect(try eval(#"aliases.join("/")"#, n).displayString == "A/B")
        #expect(try eval(#"note.rating == 4"#, n).isTruthy)
        #expect(try eval(#""a-b-c".replace("-", "+")"#, n).displayString == "a+b+c", "a string pattern replaces every occurrence")
        #expect(try eval(#""a-b-c".replace(/-/, "+")"#, n).displayString == "a+b-c", "a regex without g replaces the first")
        #expect(try eval(#""a-b-c".replace(/-/g, "+")"#, n).displayString == "a+b+c")
        #expect(try eval("formula.double", n, formulas: ["double": "rating * 2"]).displayString == "8")
        #expect(try eval("formula.loop", n, formulas: ["loop": "formula.loop"]).displayString == "", "cycles evaluate to null")
        #expect(try eval("10 / 4", n).displayString == "2.5")
    }

    @Test func tagsMatchNested() throws {
        let n = note(tags: ["project/alpha"])
        #expect(try eval(#"file.hasTag("project")"#, n).isTruthy)
        #expect(try eval(##"file.hasTag("#project/alpha")"##, n).isTruthy)
        #expect(try !eval(#"file.hasTag("proj")"#, n).isTruthy)
    }

    @Test func unsupportedFunctionsAreReported() throws {
        let evaluator = BaseEvaluator(formulas: [:])
        evaluator.begin(note())
        #expect(evaluator.evaluate(try BaseExpressionParser.parse("image(cover)"), locals: [:]).isEmptyValue)
        #expect(evaluator.unsupported == ["image()"])
    }

    @Test func malformedExpressionsThrow() {
        for source in ["a ==", "(a", "\"open", "a.", "/regex", "a @ b"] {
            #expect(throws: BaseParseError.self) { try BaseExpressionParser.parse(source) }
        }
        let deep = String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)
        #expect(throws: BaseParseError.self) { try BaseExpressionParser.parse(deep) }
    }

    @Test func sortKeysOrderLikeValues() {
        func key(_ v: BaseValue, _ asc: Bool = true) -> Data { BaseSortKey.encode(v, ascending: asc) }
        func ordered(_ values: [BaseValue], asc: Bool = true) -> Bool {
            zip(values, values.dropFirst()).allSatisfy { key($0, asc).lexicographicallyPrecedes(key($1, asc)) }
        }
        #expect(ordered([.number(-10), .number(-1.5), .number(0), .number(2), .number(1e9)]))
        #expect(ordered([.string("ab"), .string("abc"), .string("B"), .string("日本")]), "case-insensitive; a prefix first")
        #expect(ordered([.string("abc"), .string("ab"), .string("a")], asc: false), "descending")
        #expect(ordered([.number(1), .null]), "empty last ascending")
        #expect(ordered([.number(1), .null], asc: false), "empty last descending too")
        #expect(ordered([.string("x"), .string("")], asc: false))
    }
}

@Suite struct BaseBuildTests {
    func rows(_ db: Database, base: String, view: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT n.path FROM base_rows r JOIN notes n ON n.id = r.note_id JOIN assets a ON a.id = r.base_id
            WHERE a.path = ? AND r.view = ? ORDER BY r.group_key, r.sort_key, r.note_id
            """, arguments: [base, view])
    }

    func document(_ db: Database, base: String) throws -> BaseDocument {
        let json = try String.fetchOne(db, sql: "SELECT b.definition FROM bases b JOIN assets a ON a.id = b.asset_id WHERE a.path = ?", arguments: [base])
        return try JSONDecoder().decode(BaseDocument.self, from: Data(try #require(json).utf8))
    }

    @Test func fixtureBaseIsEvaluated() async throws {
        let env = try Env(copyFixture: false)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try await indexer.query { (db: Database) throws in
            let doc = try document(db, base: "Notes.base")
            #expect(doc.error == nil)
            #expect(doc.views.map(\.name) == ["By folder", "Tagged", "Name"])
            #expect(doc.views[0].grouped && !doc.views[1].grouped)
            #expect(doc.views[0].columns.map(\.label) == ["name", "Tags"])

            let byFolder = try rows(db, base: "Notes.base", view: 0)
            #expect(!byFolder.contains { $0.hasPrefix("Archive/") }, "not: file.inFolder(\"Archive\")")
            #expect(byFolder.count == 10)
            // Grouped by folder A→Z, the vault root ("" is empty) last.
            #expect(byFolder.first == "Café/Ünïcode Nöte.md")
            #expect(Array(byFolder.suffix(4)) == ["Code.md", "Empty.md", "Home.md", "Invalid YAML.md"])
            let groups = try Row.fetchAll(db, sql: "SELECT label, row_count FROM base_groups WHERE view = 0 ORDER BY group_key")
            #expect(groups.map { $0["label"] as String? } == ["Café", "Daily", "Meetings", "Projects", "日本語", nil])

            let tagged = try rows(db, base: "Notes.base", view: 1)
            #expect(tagged.first == "日本語/東京メモ.md", "name descending")
            #expect(tagged.contains("Projects/Alpha.md") && !tagged.contains("Code.md"))

            let cells = try String.fetchOne(db, sql: "SELECT c.cells FROM base_cells c JOIN notes n ON n.id = c.note_id WHERE n.path = 'Home.md'")
            let decoded = try JSONDecoder().decode([String: BaseCell].self, from: Data(try #require(cells).utf8))
            #expect(decoded["rating"] == .number(5))
            #expect(decoded["formula.tag_list"] == .list([.text("日本語"), .text("inline-tag")]), "the filter drops \"index\"")
        }
        _ = try ArtifactVerifier.verify(publishDirectory: env.config.publishDirectory)
    }

    @Test func editsRewriteOnlyAffectedRows() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        // Nothing changed: nothing to write.
        let idle = try await indexer.builder.writer.write { db in try BaseBuilder.rebuild(db) }
        #expect(idle.written == 0)

        try env.write("Projects/Gamma.md", "---\ntags: [project]\n---\n# Gamma\n")
        _ = try await indexer.process(paths: ["Projects/Gamma.md"])
        let edit = try await indexer.builder.writer.write { db in try BaseBuilder.rebuild(db) }
        // One cell, one row in each of the three views, one group count and
        // the row counts in the definition.
        #expect(edit.written == 6)
        try await indexer.query { (db: Database) throws in
            #expect(try rows(db, base: "Notes.base", view: 2).contains("Projects/Gamma.md"))
        }
    }

    @Test func baseFilesFollowTheVault() async throws {
        let env = try Env(copyFixture: true)
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()

        // A broken expression is reported; the rest of the base still works.
        try env.write("Notes.base", "filters: 'file.ext == \"md\" &&'\nviews:\n  - type: list\n    name: All\n    sort: [file.name]\n")
        _ = try await indexer.process(paths: ["Notes.base"])
        _ = try await indexer.publish()
        try await indexer.query { (db: Database) throws in
            let doc = try document(db, base: "Notes.base")
            #expect(doc.error?.contains("filter") == true)
            #expect(doc.views.map(\.name) == ["All"])
            #expect(try rows(db, base: "Notes.base", view: 0).count == 11)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM base_rows WHERE view > 0") == 0)
        }

        try env.remove("Notes.base")
        _ = try await indexer.process(paths: ["Notes.base"])
        _ = try await indexer.publish()
        try await indexer.query { (db: Database) throws in
            for table in ["bases", "base_cells", "base_rows", "base_groups"] {
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0, "\(table)")
            }
        }
    }

    @Test func linksInPropertiesAreResolved() async throws {
        let env = try Env(copyFixture: true)
        try env.write("Linked.md", "---\nup: \"[[Alpha]]\"\nrelated: [\"[[Missing]]\", \"[[Beta|the beta]]\", \"[[v1.0 notes]]\"]\n---\n")
        try env.write("Links.base", "filters: 'file.basename == \"Linked\"'\nviews:\n  - type: table\n    name: T\n    order: [file.name, up, related]\n")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        _ = try await indexer.publish()
        try await indexer.query { (db: Database) throws in
            let cells = try String.fetchOne(db, sql: "SELECT c.cells FROM base_cells c JOIN assets a ON a.id = c.base_id WHERE a.path = 'Links.base'")
            let decoded = try JSONDecoder().decode([String: BaseCell].self, from: Data(try #require(cells).utf8))
            #expect(decoded["up"] == .link(display: "Alpha", path: "Projects/Alpha.md"))
            #expect(decoded["related"] == .list([
                .link(display: "Missing", path: nil), .link(display: "the beta", path: "Projects/Beta.md"),
                .link(display: "v1.0 notes", path: nil),
            ]), "a dot in a note name is not an extension")
        }
    }

    @Test func linksToBasesResolveToTheBase() async throws {
        let env = try Env(copyFixture: true)
        try env.write("Index.md", "See [[Notes.base]] and ![[Notes.base]].\n")
        let indexer = try Indexer(configuration: env.config)
        _ = try await indexer.reconcile()
        try await indexer.query { (db: Database) throws in
            #expect(try linkTarget(db, from: "Index.md", ordinal: 0) == "Notes.base")
            #expect(try linkTarget(db, from: "Index.md", ordinal: 1) == "Notes.base")
        }
    }
}
