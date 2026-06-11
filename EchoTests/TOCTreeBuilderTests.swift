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

    // MARK: - Publisher-declared TOC entries (NCX / nav)

    private func entry(
        id: String,
        parent: String? = nil,
        order: Int,
        depth: Int,
        title: String,
        blockID: String?
    ) -> EPubTOCEntryRecord {
        EPubTOCEntryRecord(
            id: id,
            audiobookID: "book-1",
            parentID: parent,
            orderIndex: order,
            depth: depth,
            title: title,
            blockID: blockID,
            spineIndex: nil
        )
    }

    @Test func tocEntriesBuildTreeWithPublisherTitlesAndNesting() {
        // Blocks carry source-mangled-ish titles; the tree must show the
        // publisher's NCX labels ("Topic 3. Software Entropy") and nesting,
        // not the per-file heading heuristic.
        let blocks = [
            block(id: "b0", spine: 0, text: "Foreword"),
            block(id: "b1", spine: 1, text: "Chapter 1 A Pragmatic Philosophy"),
            block(id: "b2", spine: 2, text: "Topic 3 Software Entropy"),
            block(id: "b3", spine: 2, text: "Challenges"),
        ]
        let entries = [
            entry(id: "t0", order: 0, depth: 0, title: "Foreword", blockID: "b0"),
            entry(id: "t1", order: 1, depth: 0, title: "1. A Pragmatic Philosophy", blockID: "b1"),
            entry(id: "t2", parent: "t1", order: 2, depth: 1, title: "Topic 3. Software Entropy", blockID: "b2"),
        ]
        let nodes = TOCTreeBuilder.build(from: blocks, tocEntries: entries)

        #expect(nodes.map(\.title) == ["Foreword", "1. A Pragmatic Philosophy"])
        #expect(nodes.last?.children.map(\.title) == ["Topic 3. Software Entropy"])
        #expect(nodes.last?.children.first?.blockID == "b2")
        // The in-file h3 must not surface as a top-level chapter.
        #expect(!nodes.contains { $0.title == "Challenges" })
    }

    @Test func entryWithoutBlockFallsBackToFirstDescendantTarget() {
        let blocks = [block(id: "b1", spine: 1, text: "Topic 1 It's Your Life")]
        let entries = [
            entry(id: "t0", order: 0, depth: 0, title: "1. A Pragmatic Philosophy", blockID: nil),
            entry(id: "t1", parent: "t0", order: 1, depth: 1, title: "Topic 1. It's Your Life", blockID: "b1"),
        ]
        let nodes = TOCTreeBuilder.build(from: blocks, tocEntries: entries)
        #expect(nodes.first?.blockID == "b1")
        #expect(nodes.first?.children.first?.blockID == "b1")
    }

    @Test func entryWithNoTargetAnywhereIsDropped() {
        let blocks = [block(id: "b0", spine: 0, text: "Chapter One")]
        let entries = [
            entry(id: "t0", order: 0, depth: 0, title: "Chapter One", blockID: "b0"),
            entry(id: "t1", order: 1, depth: 0, title: "Ghost Chapter", blockID: nil),
        ]
        let nodes = TOCTreeBuilder.build(from: blocks, tocEntries: entries)
        #expect(nodes.map(\.title) == ["Chapter One"])
    }

    @Test func emptyTOCEntriesFallBackToHeadingHeuristic() {
        let nodes = TOCTreeBuilder.build(
            from: [
                block(id: "b0", spine: 0, text: "Chapter One"),
                block(id: "b1", spine: 0, text: "Team Trust"),
            ],
            tocEntries: []
        )
        #expect(nodes.count == 1)
        #expect(nodes.first?.title == "Chapter One")
        #expect(nodes.first?.children.map(\.title) == ["Team Trust"])
    }

    @Test func leadingFrontMatterEntriesCollapseIntoGroup() {
        // Junk titles ("Praise for…", "Cover") are dropped outright — see
        // junkEntryTitlesAreDroppedWithChildrenPromoted — so the group holds
        // the *content-bearing* front matter (forewords, prefaces).
        let blocks = [
            block(id: "b0", spine: 0, text: "Foreword", frontMatter: true),
            block(id: "b1", spine: 1, text: "Preface to the Second Edition", frontMatter: true),
            block(id: "b2", spine: 2, text: "Chapter One"),
        ]
        let entries = [
            entry(id: "t0", order: 0, depth: 0, title: "Foreword", blockID: "b0"),
            entry(id: "t1", order: 1, depth: 0, title: "Preface to the Second Edition", blockID: "b1"),
            entry(id: "t2", order: 2, depth: 0, title: "Chapter One", blockID: "b2"),
        ]
        let nodes = TOCTreeBuilder.build(from: blocks, tocEntries: entries)
        #expect(nodes.map(\.title) == ["Front Matter", "Chapter One"])
        #expect(nodes.first?.children.map(\.title) == ["Foreword", "Preface to the Second Edition"])
    }

    @Test func junkEntryTitlesAreDroppedWithChildrenPromoted() {
        let blocks = [
            block(id: "b0", spine: 0, text: "Contents"),
            block(id: "b1", spine: 1, text: "Chapter One"),
        ]
        let entries = [
            entry(id: "t0", order: 0, depth: 0, title: "Contents", blockID: "b0"),
            entry(id: "t1", parent: "t0", order: 1, depth: 1, title: "Chapter One", blockID: "b1"),
        ]
        let nodes = TOCTreeBuilder.build(from: blocks, tocEntries: entries)
        #expect(nodes.map(\.title) == ["Chapter One"])
    }
}
