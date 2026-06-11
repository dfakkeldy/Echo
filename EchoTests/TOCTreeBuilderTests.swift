import Testing
@testable import Echo

/// Tests for the Table of Contents tree built from imported EPUB blocks.
///
/// The tree must not invent chapters: junk headings are skipped, spines
/// without headings produce no filename-derived rows (the "F 0001" bug), and
/// leading front-matter entries collapse into one expandable group.
struct TOCTreeBuilderTests {

    private func block(
        id: String,
        spine: Int,
        kind: EPubBlockRecord.Kind = .heading,
        text: String?,
        href: String = "file.xhtml",
        frontMatter: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book-1",
            spineHref: href,
            spineIndex: spine,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind.rawValue,
            text: text,
            isHidden: false,
            isFrontMatter: frontMatter
        )
    }

    @Test func junkHeadingsCreateNoNodes() {
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Cover", frontMatter: true),
            block(id: "b1", spine: 1, text: "Table of Contents", frontMatter: true),
            block(id: "b2", spine: 2, text: "Chapter One"),
        ])
        #expect(nodes.count == 1)
        #expect(nodes.first?.title == "Chapter One")
    }

    @Test func spineWithoutHeadingProducesNoFilenameNode() {
        // f_0001.xhtml has only a paragraph — the old code fabricated an
        // "F 0001" chapter from the filename.
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, kind: .paragraph, text: "An image page.", href: "f_0001.xhtml", frontMatter: true),
            block(id: "b1", spine: 1, text: "Chapter One"),
        ])
        #expect(nodes.count == 1)
        #expect(nodes.first?.title == "Chapter One")
        #expect(!nodes.contains { $0.title == "F 0001" })
    }

    @Test func leadingFrontMatterNodesCollapseIntoOneGroup() {
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Foreword", frontMatter: true),
            block(id: "b1", spine: 1, text: "Preface to the Second Edition", frontMatter: true),
            block(id: "b2", spine: 2, text: "Chapter One"),
            block(id: "b3", spine: 3, text: "Chapter Two"),
        ])
        #expect(nodes.count == 3)
        #expect(nodes.first?.title == "Front Matter")
        #expect(nodes.first?.children.map(\.title) == ["Foreword", "Preface to the Second Edition"])
        #expect(nodes[1].title == "Chapter One")
        #expect(nodes[2].title == "Chapter Two")
    }

    @Test func singleFrontMatterNodeStaysInline() {
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Foreword", frontMatter: true),
            block(id: "b1", spine: 1, text: "Chapter One"),
        ])
        #expect(nodes.map(\.title) == ["Foreword", "Chapter One"])
    }

    @Test func partHeadingsNestFollowingChapters() {
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Part One The Basics"),
            block(id: "b1", spine: 1, text: "Chapter One"),
            block(id: "b2", spine: 2, text: "Chapter Two"),
        ])
        #expect(nodes.count == 1)
        #expect(nodes.first?.title == "Part One The Basics")
        #expect(nodes.first?.children.map(\.title) == ["Chapter One", "Chapter Two"])
    }

    @Test func subsequentHeadingsInSpineBecomeSections() {
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Chapter One"),
            block(id: "b1", spine: 0, text: "Team Trust"),
            block(id: "b2", spine: 0, text: "First, Do No Harm"),
        ])
        #expect(nodes.count == 1)
        #expect(nodes.first?.children.map(\.title) == ["Team Trust", "First, Do No Harm"])
    }

    @Test func mangledLegacyTitlesAreFlattenedForDisplay() {
        // Blocks imported before the whitespace fix may still carry interior
        // newlines; the tree must normalize them for display.
        let nodes = TOCTreeBuilder.build(from: [
            block(id: "b0", spine: 0, text: "Chapter\n      1 A Pragmatic Philosophy"),
        ])
        #expect(nodes.first?.title == "Chapter 1 A Pragmatic Philosophy")
    }
}
