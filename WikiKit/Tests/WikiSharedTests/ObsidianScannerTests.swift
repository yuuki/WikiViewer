import Testing
@testable import WikiShared

@Suite struct ObsidianScannerTests {
    let scanner = ObsidianScanner()

    @Test func wikilinkVariants() {
        let doc = scanner.scan("""
        See [[note]], [[path/to/note]], [[note|label]], [[note#Heading]], [[note#^block-id]].
        Same note: [[#Local heading]]. Table: [[note\\|escaped]]
        """)
        let targets = doc.links.map(\.target)
        #expect(targets == [
            LinkTarget(path: "note"),
            LinkTarget(path: "path/to/note"),
            LinkTarget(path: "note", display: "label"),
            LinkTarget(path: "note", heading: "Heading"),
            LinkTarget(path: "note", blockID: "block-id"),
            LinkTarget(path: "", heading: "Local heading"),
            LinkTarget(path: "note", display: "escaped"),
        ])
        #expect(doc.links.allSatisfy { $0.kind == .wiki && !$0.isEmbed })
        #expect(doc.links[5].line == 1)
    }

    @Test func embeds() {
        let doc = scanner.scan("![[image.png]] ![[image.png|300]] ![[note]] ![[note#Heading]] ![alt](assets/pic.jpg)")
        #expect(doc.links.count == 5)
        #expect(doc.links.allSatisfy { $0.isEmbed })
        #expect(doc.links[1].target.display == "300")
        #expect(doc.links[3].target.heading == "Heading")
        #expect(doc.links[4].kind == .markdown)
        #expect(doc.links[4].target.path == "assets/pic.jpg")
        #expect(doc.links[4].text == "alt")
    }

    @Test func markdownLinks() {
        let doc = scanner.scan("[a](file.md) [b](My%20Note.md#Sec) [c](<with space.md>) [ext](https://example.com) [mail](mailto:x@y) [h](#Local)")
        #expect(doc.links.map(\.target.path) == ["file.md", "My Note.md", "with space.md", ""])
        #expect(doc.links[1].target.heading == "Sec")
        #expect(doc.links[3].target.heading == "Local")
    }

    @Test func tokenRangesCoverWholeToken() {
        let text = "x ![[a.png|3]] y [[b]] z"
        let doc = scanner.scan(text)
        let bytes = Array(text.utf8)
        let slices = doc.links.map { String(decoding: bytes[$0.range], as: UTF8.self) }
        #expect(slices == ["![[a.png|3]]", "[[b]]"])
    }

    @Test func skipsCode() {
        let doc = scanner.scan("""
        `[[inline code]]` and ``[[double `tick`]]``
        ```
        [[fenced]] #nottag
        ```
        ~~~md
        [[tilde fenced]]
        ~~~
        > ```
        > [[quoted fence]]
        > ```
        $$
        [[math]]
        $$
        after [[real]]
        """)
        #expect(doc.links.map(\.target.path) == ["real"])
        #expect(doc.tags.isEmpty)
    }

    @Test func skipsComments() {
        let doc = scanner.scan("""
        visible [[a]] %%hidden [[b]]%% <!-- html [[c]] -->
        %%
        multi [[d]]
        %%
        tail [[e]]
        """)
        #expect(doc.links.map(\.target.path) == ["a", "e"])
        #expect(doc.hiddenRanges.count == 3)
    }

    @Test func tags() {
        let doc = scanner.scan("""
        #top line with #tag and #nested/tag and #日本語タグ and #tag_2-x.
        Not tags: a#b, #123, [[x#y]], http://e.com/#frag, #
        # Heading #inheading
        """)
        #expect(doc.tags.map(\.name) == ["top", "tag", "nested/tag", "日本語タグ", "tag_2-x", "inheading"])
    }

    @Test func headings() {
        let doc = scanner.scan("""
        # Title
        text
        ## Second ##
        #NotHeading
        Setext One
        ==========
        Setext Two
        ----------

        ---
        ####### seven hashes
        """)
        #expect(doc.headings.map(\.text) == ["Title", "Second", "Setext One", "Setext Two"])
        #expect(doc.headings.map(\.level) == [1, 2, 1, 2])
        #expect(doc.headings.map(\.line) == [0, 2, 4, 6])
    }

    @Test func blockIDs() {
        let doc = scanner.scan("""
        A paragraph with id ^abc-123
        ^standalone
        not an id^x
        trailing [[link]] ^after-link
        """)
        #expect(doc.blockIDs.map(\.id) == ["abc-123", "standalone", "after-link"])
        #expect(doc.blockIDs.map(\.line) == [0, 1, 3])
    }

    @Test func japaneseAndUnicode() {
        let doc = scanner.scan("日本語の[[東京 メモ|とうきょう]]と[[Café/Ünïcode]]。#タグ は前に空白が必要")
        #expect(doc.links.map(\.target.path) == ["東京 メモ", "Café/Ünïcode"])
        #expect(doc.links[0].target.display == "とうきょう")
        #expect(doc.tags.isEmpty, "Obsidian requires whitespace before '#'")
    }

    @Test func unterminatedConstructsAreText() {
        let doc = scanner.scan("[[open without close\n[text](no-close\n![[]] [[ ]]")
        #expect(doc.links.count == 1)
        #expect(doc.links[0].target.path == "")
    }

    @Test func emptyAndCRLF() {
        #expect(scanner.scan("") == ScannedDocument())
        let doc = scanner.scan("# H\r\n[[a]] ^id\r\n")
        #expect(doc.headings.map(\.text) == ["H"])
        #expect(doc.blockIDs.map(\.id) == ["id"])
    }
}

@Suite struct FrontmatterTests {
    @Test func splitsFrontmatter() {
        let split = Frontmatter.split("---\ntags: [a]\n---\nBody\n")
        #expect(split.yaml == "tags: [a]")
        #expect(split.body == "Body\n")
    }

    @Test func noFrontmatter() {
        #expect(Frontmatter.split("Body").yaml == nil)
        #expect(Frontmatter.split("---x\n---\n").yaml == nil)
        #expect(Frontmatter.split("---\nunterminated").yaml == nil)
        #expect(Frontmatter.split("---\nunterminated").body == "---\nunterminated")
    }

    @Test func emptyFrontmatterAndBOM() {
        let split = Frontmatter.split("\u{FEFF}---\n---\n# T")
        #expect(split.yaml == "")
        #expect(split.body == "# T")
    }
}

@Suite struct VaultPathTests {
    @Test func normalize() {
        #expect(VaultPath.normalizeRelative("./a//b/../c.md") == "a/c.md")
        #expect(VaultPath.normalizeRelative("../x") == nil)
        #expect(VaultPath.normalizeRelative("/abs/x") == "abs/x")
        #expect(VaultPath.normalizeRelative("") == nil)
        #expect(VaultPath.normalizeRelative("Cafe\u{0301}.md") == "Café.md")
    }

    @Test func parts() {
        #expect(VaultPath.basename(of: "a/b/Note.md") == "Note")
        #expect(VaultPath.basename(of: ".hidden") == ".hidden")
        #expect(VaultPath.folder(of: "a/b/Note.md") == "a/b")
        #expect(VaultPath.folder(of: "Note.md") == "")
        #expect(VaultPath.fileExtension(of: "x/IMG.PNG") == "png")
    }

    @Test func safety() {
        #expect(VaultPath.isSafeRelative("a/b.md"))
        #expect(!VaultPath.isSafeRelative("../a"))
        #expect(!VaultPath.isSafeRelative("/a"))
        #expect(!VaultPath.isSafeRelative("a//b"))
    }

    @Test func headingKey() {
        #expect(HeadingKey.make("My Heading: Part 2!") == HeadingKey.make("my heading part 2"))
        #expect(HeadingKey.make("日本語 見出し") == "日本語見出し")
        #expect(HeadingKey.lastComponent(of: "A#B#C") == "C")
    }
}

/// Regressions found in review.
@Suite struct ScannerReviewRegressions {
    let scanner = ObsidianScanner()

    @Test func unmatchedBracketsAreLinear() {
        let text = String(repeating: "[a", count: 200_000) // 400 KB on one line
        let start = ContinuousClock.now
        let doc = scanner.scan(text)
        #expect(doc.links.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(2), "was quadratic (11 s at 400 KB)")
    }

    @Test func fenceInsideCalloutEndsWithTheQuote() {
        let doc = scanner.scan("> [!note]\n> ```\n> code [[NotLink]]\n\nafter [[Lost]] #lost")
        #expect(doc.links.map(\.target.path) == ["Lost"])
        #expect(doc.tags.map(\.name) == ["lost"])
    }

    @Test func setextFalsePositives() {
        #expect(scanner.scan("1. item\n---").headings.isEmpty)
        #expect(scanner.scan("> para\n---").headings.isEmpty)
        #expect(scanner.scan("- item\n  more\n---").headings.isEmpty)
        #expect(scanner.scan("Para\n---").headings.map(\.text) == ["Para"])
    }

    @Test func blockIDInsideCommentIsIgnored() {
        #expect(scanner.scan("text %% secret ^abc\nstill hidden %%").blockIDs.isEmpty)
        #expect(scanner.scan("text %%c%% ^real").blockIDs.map(\.id) == ["real"])
    }

    @Test func codeSpansInsideLinkText() {
        let doc = scanner.scan("[`]`](Note.md)")
        #expect(doc.links.map(\.target.path) == ["Note.md"])
    }

    @Test func emojiTags() {
        let doc = scanner.scan("#👨‍💻dev and #a️⃣ and #tag🎉")
        #expect(doc.tags.map(\.name) == ["👨‍💻dev", "a️⃣", "tag🎉"])
    }

    @Test func crlfFrontmatter() {
        let split = Frontmatter.split("---\r\ntags: [crlf]\r\ntitle: CRLF Title\r\n---\r\nBody\r\n")
        #expect(split.yaml == "tags: [crlf]\r\ntitle: CRLF Title")
        #expect(split.body == "Body\r\n")
    }
}
