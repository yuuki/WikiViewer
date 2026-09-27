import Foundation
import Testing
import WikiShared
@testable import WikiViewerKit

@Suite struct RendererTests {
    func link(_ ordinal: Int, _ raw: String, note: Int64? = nil, asset: Int64? = nil, embed: Bool = false) -> OutgoingLink {
        let target = raw.contains("](") ? LinkTarget(path: raw) : LinkTarget.parseWiki(raw)
        return OutgoingLink(ordinal: ordinal, kind: .wiki, isEmbed: embed, raw: raw, targetPath: target.path, heading: target.heading,
                            blockID: target.blockID, display: target.display, targetNoteID: note, targetAssetID: asset)
    }

    func links(in text: AttributedString) -> [(String, WikiLinkAction?)] {
        text.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(text[run.range].characters), WikiLinkAction(url: url))
        }
    }

    func paragraphs(_ note: RenderedNote) -> [AttributedString] {
        note.blocks.compactMap { if case .paragraph(let t) = $0.kind { t } else { nil } }
    }

    @Test func findsFirstBlockContainingText() {
        let body = "# Title\n\nFirst paragraph.\n\n- item with [[Alpha|the alpha]]\n\n> quoted Tokyo text\n\nAnother Tokyo."
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [link(0, "Alpha|the alpha", note: 2)])
        func kind(_ id: Int?) -> String? {
            guard let id, let block = rendered.blocks.first(where: { $0.id == id }) else { return nil }
            return block.plainText
        }
        #expect(kind(rendered.firstBlock(containing: "tokyo")) == "quoted Tokyo text")
        #expect(kind(rendered.firstBlock(containing: "THE ALPHA")) == "item with the alpha")
        #expect(rendered.firstBlock(containing: "Alpha|") == nil, "link syntax is not visible text")
        #expect(rendered.firstBlock(containing: "  ") == nil)
        #expect(rendered.firstBlock(containing: "absent") == nil)
    }

    @Test func wikilinksBecomeResolvedLinks() {
        let body = "See [[Alpha|the alpha]], [[Beta#Goals]], [[Missing]] and [[#Local]]."
        let rendered = NoteRenderer.render(body: body, noteID: 7, links: [
            link(0, "Alpha|the alpha", note: 1),
            link(1, "Beta#Goals", note: 2),
            link(2, "Missing"),
            link(3, "#Local"),
        ])
        let found = links(in: paragraphs(rendered)[0])
        #expect(found.map(\.0) == ["the alpha", "Beta > Goals", "Missing", "Local"])
        #expect(found.map(\.1) == [
            .note(id: 1, heading: nil, blockID: nil),
            .note(id: 2, heading: "Goals", blockID: nil),
            .missing(target: "Missing"),
            .note(id: 7, heading: "Local", blockID: nil),
        ])
    }

    @Test func frontmatterWikilinksBecomeLinks() {
        let rows = [
            link(0, "Home", note: 1),
            link(1, "Home", note: 1),
            link(2, "Beta#Goals", note: 2),
            link(3, "Missing"),
        ]
        let up = NoteRenderer.propertyText(.text("[[Home]]"), noteID: 7, links: rows)
        #expect(String(up.characters) == "Home")
        #expect(links(in: up).map(\.1) == [.note(id: 1, heading: nil, blockID: nil)])

        let related = NoteRenderer.propertyText(.list([.text("see [[Beta#Goals]]"), .text("[[Missing]]"), .number("3")]), noteID: 7, links: rows)
        #expect(String(related.characters) == "see Beta > Goals, Missing, 3")
        #expect(links(in: related).map(\.1) == [.note(id: 2, heading: "Goals", blockID: nil), .missing(target: "Missing")])

        let plain = NoteRenderer.propertyText(.text("[text](Beta.md)"), noteID: 7, links: rows)
        #expect(links(in: plain).isEmpty, "only wikilinks are links in properties")
    }

    @Test func labelsAreLiteralText() {
        let rendered = NoteRenderer.render(body: "[[a*b*|*not emphasis* [x](y)]]", noteID: 1, links: [link(0, "a*b*|*not emphasis* [x](y)", note: 2)])
        let found = links(in: paragraphs(rendered)[0])
        #expect(found.map(\.0) == ["*not emphasis* [x](y)"])
    }

    @Test func codeCommentsAndTags() {
        let body = """
        Inline `[[code]]` stays. %%hidden [[x]]%% visible #tag/nested

        ```
        [[fenced]] #nottag
        ```
        """
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        let para = paragraphs(rendered)[0]
        let text = String(para.characters)
        #expect(text.contains("[[code]]"))
        #expect(!text.contains("hidden"))
        #expect(links(in: para).map(\.1) == [.tag("tag/nested")])
        guard case .code(_, let code, _) = rendered.blocks.last?.kind else { Issue.record("expected code block"); return }
        #expect(code == "[[fenced]] #nottag")
    }

    @Test func embedsBecomeBlocks() {
        let body = "Before ![[img.png|300]] after\n\n![[Note#Sec]]\n\n![[Gone]]"
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [
            link(0, "img.png|300", asset: 42, embed: true),
            link(1, "Note#Sec", note: 9, embed: true),
            link(2, "Gone", embed: true),
        ])
        let kinds = rendered.blocks.map { block -> String in
            switch block.kind {
            case .paragraph(let t): "p:" + String(t.characters)
            case .embed(.asset(let id, _, let spec)): "asset:\(id):\(spec ?? "")"
            case .embed(.note(let id, _, let heading, _)): "note:\(id):\(heading ?? "")"
            case .embed(.missing(let raw)): "missing:\(raw)"
            default: "other"
            }
        }
        #expect(kinds == ["p:Before", "asset:42:300", "p:after", "note:9:Sec", "missing:Gone"])

        let flat = NoteRenderer.render(body: body, noteID: 1, links: [link(0, "img.png|300", asset: 42, embed: true)], allowEmbeds: false)
        #expect(!flat.blocks.contains { if case .embed = $0.kind { true } else { false } }, "nested embeds are flattened to links")
    }

    @Test func headingAndBlockAnchors() throws {
        let body = """
        # Title
        Intro paragraph ^intro

        ## Second Heading
        Para
        ^standalone
        """
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        #expect(rendered.headings.map(\.text) == ["Title", "Second Heading"])
        let second = try #require(rendered.headingAnchors[HeadingKey.make("second heading")])
        #expect(rendered.blocks.first { $0.id == second }.map { if case .heading = $0.kind { true } else { false } } == true)
        let intro = try #require(rendered.blockAnchors["intro"])
        guard case .paragraph(let text) = rendered.blocks.first(where: { $0.id == intro })?.kind else { Issue.record("intro"); return }
        #expect(String(text.characters) == "Intro paragraph", "^id marker is not displayed")
        let standalone = try #require(rendered.blockAnchors["standalone"])
        guard case .paragraph(let para) = rendered.blocks.first(where: { $0.id == standalone })?.kind else { Issue.record("standalone"); return }
        #expect(String(para.characters) == "Para")
    }

    @Test func calloutsListsTables() {
        let body = """
        > [!warning]- Careful now
        > Body with **bold**

        - [ ] open
        - [x] done
          - nested

        3. three
        4. four

        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        guard case .callout(let type, let title, let foldable, let children) = rendered.blocks[0].kind else { Issue.record("callout"); return }
        #expect(type == "warning")
        #expect(String(title.characters) == "Careful now")
        #expect(foldable)
        #expect(children.count == 1)
        let items = rendered.blocks.compactMap { b -> (ListMarker, Int)? in
            if case .listItem(let marker, let depth, _) = b.kind { (marker, depth) } else { nil }
        }
        #expect(items.map(\.0) == [.task(done: false), .task(done: true), .bullet, .number(3), .number(4)])
        #expect(items.map(\.1) == [0, 0, 1, 0, 0], "nested list flattened with depth")
        guard case .table(let header2, let rows2) = rendered.blocks.last?.kind else { Issue.record("table"); return }
        let (header, rows) = (header2, rows2)
        #expect(header.map { String($0.characters) } == ["A", "B"])
        #expect(rows.count == 1)
    }

    @Test func excerpts() {
        let body = "# A\na1\n## B\nb1 ^blk\n## C\nc1\n# D\nd1"
        #expect(NoteRenderer.excerpt(body: body, heading: "B", blockID: nil) == "## B\nb1 ^blk")
        #expect(NoteRenderer.excerpt(body: body, heading: "A", blockID: nil) == "# A\na1\n## B\nb1 ^blk\n## C\nc1")
        #expect(NoteRenderer.excerpt(body: body, heading: nil, blockID: "blk") == "b1 ^blk")
        #expect(NoteRenderer.excerpt(body: body, heading: "Nope", blockID: nil) == body)
    }

    @Test func renderingFixtureNotes() async throws {
        let db = try openDemo()
        let session = LibrarySession(database: db, installed: nil)
        let homeID = try #require(try await session.notes.noteID(path: "Home.md"))
        let home = try #require(try await session.notes.note(id: homeID))
        let rendered = NoteRenderer.render(body: home.body, noteID: homeID, links: try await session.links.outgoingLinks(of: homeID))
        let all = rendered.blocks.flatMap { block -> [WikiLinkAction?] in
            switch block.kind {
            case .listItem(_, _, let blocks):
                blocks.flatMap { b -> [WikiLinkAction?] in
                    if case .paragraph(let t) = b.kind { links(in: t).map(\.1) } else { [] }
                }
            case .paragraph(let t): links(in: t).map(\.1)
            default: []
            }
        }
        #expect(all.contains(.missing(target: "Nonexistent Note")))
        #expect(all.contains(.external(URL(string: "https://obsidian.md")!)))
        let embeds = rendered.blocks.compactMap { if case .embed(let e) = $0.kind { e } else { nil } }
        #expect(embeds.count == 3)
        #expect(rendered.blockAnchors["home-block"] != nil)
        #expect(rendered.blocks.contains { if case .callout("note", _, _, _) = $0.kind { true } else { false } })
    }

    @Test func largeBlocksAreSplitIntoLazyRows() {
        let code = "```\n" + (0..<1000).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let list = (0..<5000).map { "- item \($0)" }.joined(separator: "\n")
        let table = "| a |\n|---|\n" + (0..<500).map { "| \($0) |" }.joined(separator: "\n")
        let rendered = NoteRenderer.render(body: code + "\n\n" + list + "\n\n" + table, noteID: 1, links: [])
        let codeParts = rendered.blocks.filter { if case .code = $0.kind { true } else { false } }
        #expect(codeParts.count == 7)
        let items = rendered.blocks.filter { if case .listItem = $0.kind { true } else { false } }
        #expect(items.count == 5000)
        let tables = rendered.blocks.filter { if case .table = $0.kind { true } else { false } }
        #expect(tables.count == 9)
    }

    @Test func unsafeSchemesAreNotLinks() {
        let rendered = NoteRenderer.render(body: "[call](tel:123) [x](shortcuts://run) [f](file:///etc/passwd) [ok](https://example.com)", noteID: 1, links: [])
        let found = links(in: paragraphs(rendered)[0])
        #expect(found.map(\.0) == ["ok"])
    }

    @Test func parenthesesInTargets() {
        let rendered = NoteRenderer.render(body: "[[Foo (draft)]] and [[Note#Step 1)]]", noteID: 1, links: [])
        let found = links(in: paragraphs(rendered)[0])
        #expect(found.map(\.0) == ["Foo (draft)", "Note > Step 1)"])
        #expect(found.map(\.1) == [.missing(target: "Foo (draft)"), .missing(target: "Note")])
    }

    @Test func crlfExcerptDoesNotCrash() {
        let body = "# A\r\ntext\r\n## B\r\nb1 ^blk\r\n"
        #expect(NoteRenderer.excerpt(body: body, heading: "B", blockID: nil).hasPrefix("## B"))
        #expect(NoteRenderer.excerpt(body: body, heading: nil, blockID: "blk").contains("b1"))
    }

    func math(in text: AttributedString) -> [String] {
        text.runs.compactMap { $0[MathAttribute.self] }
    }

    @Test func inlineMathIsNotMarkdown() {
        let body = #"Energy $E = mc^2$ and $a_1 * b_1 \cdot x_{i}$, not `$code$` or \$5 or $5 and $6."#
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        let text = paragraphs(rendered)[0]
        #expect(math(in: text) == ["E = mc^2", #"a_1 * b_1 \cdot x_{i}"#])
        #expect(String(text.characters) == #"Energy E = mc^2 and a_1 * b_1 \cdot x_{i}, not $code$ or $5 or $5 and $6."#)
        #expect(!text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "* and _ inside math are not emphasis")
    }

    @Test func displayMathBecomesBlocks() {
        let body = """
        Before
        $$
        \\sum_{i=1}^n i = \\frac{n(n+1)}{2}
        $$
        After ^after

        > [!note] Formula
        > $$x^2$$

        Inline $$y$$ display
        ```
        $$not math$$
        ```
        """
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        let blocks = rendered.blocks.map { block -> String in
            switch block.kind {
            case .math(let latex): "math:" + latex
            case .paragraph(let text): "p:" + String(text.characters)
            case .callout(_, _, _, let children): "callout:" + children.map { if case .math(let l) = $0.kind { l } else { "?" } }.joined()
            case .code(_, let code, _): "code:" + code
            default: "?"
            }
        }
        #expect(blocks == ["p:Before", #"math:\sum_{i=1}^n i = \frac{n(n+1)}{2}"#, "p:After", "callout:x^2", "p:Inline", "math:y", "p:display", "code:$$not math$$"])
        let after = try? #require(rendered.blocks.first { if case .paragraph(let t) = $0.kind { String(t.characters) == "After" } else { false } })
        #expect(rendered.blockAnchors["after"] == after?.id, "line numbers survive a multi-line math block")
        #expect(rendered.blocks[1].plainText.hasPrefix(#"\sum"#))
        let titled = NoteRenderer.render(body: "> [!tip] First $n$ **bold** things", noteID: 1, links: [])
        guard case .callout(_, let title, _, _) = titled.blocks.first?.kind else { Issue.record("callout"); return }
        #expect(String(title.characters) == "First n bold things")
    }

    @Test func mathHidesTagsAndSpansQuotes() {
        let body = "Set $a #b$ here\n\n> $$\n> \\alpha\n> $$\n> still quoted"
        let rendered = NoteRenderer.render(body: body, noteID: 1, links: [])
        #expect(math(in: paragraphs(rendered)[0]) == ["a #b"])
        #expect(links(in: paragraphs(rendered)[0]).isEmpty, "a # inside math is not a tag")
        guard case .quote(let children) = rendered.blocks.last?.kind else { Issue.record("quote"); return }
        #expect(children.map(\.plainText) == [#"\alpha"#, "still quoted"])
    }

    @Test func unclosedMathIsText() {
        let rendered = NoteRenderer.render(body: "$$\nnot closed\n\nCost $ 5 and $x $.", noteID: 1, links: [])
        #expect(!rendered.blocks.contains { if case .math = $0.kind { true } else { false } })
        #expect(rendered.blocks.allSatisfy { math(in: ($0.kind.paragraphText ?? AttributedString())).isEmpty })
    }

    @Test func urlRoundTrip() {
        for action: WikiLinkAction in [.note(id: 3, heading: "日本 語", blockID: nil), .note(id: 4, heading: nil, blockID: "b-1"), .missing(target: "a/b c#?"), .missing(target: "Tom & Jerry = x+y"), .note(id: 5, heading: "Q&A", blockID: nil), .tag("タグ/x"), .asset(id: 9)] {
            #expect(WikiLinkAction(url: action.url) == action)
        }
        #expect(WikiLinkAction(url: URL(string: "javascript:alert(1)")!) == nil)
        #expect(WikiLinkAction(url: URL(string: "file:///etc/passwd")!) == nil)
    }
}

private extension RenderBlock.Kind {
    var paragraphText: AttributedString? {
        if case .paragraph(let t) = self { t } else { nil }
    }
}
