// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct ReaderFeedDisplayBuilderTests {
    /// Minimal `EPubBlockRecord` fixture — only the fields the feed reads matter.
    private func block(_ id: String, chapter: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "c.xhtml", spineIndex: 0, blockIndex: 0,
            sequenceIndex: 0, blockKind: "paragraph", text: id, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapter, isHidden: false,
            hiddenReason: nil, wordCount: nil, markers: nil, textFormats: nil, createdAt: nil,
            modifiedAt: nil)
    }

    /// Chapter 0 = two sub-sections; chapter 1 = one sub-section. Front matter -1.
    private func sampleSections() -> [ReaderCardSection] {
        [
            ReaderCardSection(
                id: "ch-1-s0", headingStack: [""], items: [.block(block("fm-1", chapter: -1))]),
            ReaderCardSection(
                id: "ch0-s0", headingStack: ["Chapter 1"],
                items: [.block(block("c0-a", chapter: 0))]),
            ReaderCardSection(
                id: "ch0-s1", headingStack: ["Chapter 1", "1.1"],
                items: [.block(block("c0-b", chapter: 0))]),
            ReaderCardSection(
                id: "ch1-s0", headingStack: ["Chapter 2"],
                items: [.block(block("c1-a", chapter: 1))]),
        ]
    }

    // MARK: chapterKey parsing

    @Test func parsesPositiveAndNegativeChapterKeys() {
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch0-s0") == 0)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch10-s2") == 10)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch-1-s0") == -1)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "search") == nil)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "nonsense") == nil)
    }

    // MARK: grouping

    @Test func groupsSectionsByChapterPreservingOrder() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        #expect(groups.map(\.chapterKey) == [-1, 0, 1])
        #expect(groups[0].title == "Front Matter")  // empty title -> fallback
        #expect(groups[1].title == "Chapter 1")
        #expect(groups[1].sections.count == 2)  // ch0 has s0 + s1
        #expect(groups[1].hasAudio == true)
        #expect(groups[2].hasAudio == false)
    }

    // MARK: display sections — collapsed

    @Test func collapsedShowsOneHeaderRowPerChapter() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        let display = ReaderFeedDisplayBuilder.displaySections(
            groups: groups, openChapterKey: nil)
        // One section per chapter, each carrying only its header item.
        #expect(display.count == 3)
        #expect(display.map(\.id) == ["ch-1-s0", "ch0-s0", "ch1-s0"])
        #expect(display.allSatisfy { $0.items.count == 1 })
        // Pin the front-matter header id (key -1 -> "ch--1", double hyphen). The
        // whole reconfigure path interpolates "ch-\(key)" independently; this test
        // guards the two interpolations agreeing.
        #expect(display[0].items.map(\.id) == ["ch--1"])
        #expect(display[1].items.map(\.id) == ["ch-0"])  // header id for chapter 0
    }

    // MARK: display sections — expanded

    @Test func expandedChapterShowsHeaderThenAllItsContent() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        let display = ReaderFeedDisplayBuilder.displaySections(
            groups: groups, openChapterKey: 0)
        // Chapter 0 expands to its two sub-sections; others stay header-only.
        #expect(display.map(\.id) == ["ch-1-s0", "ch0-s0", "ch0-s1", "ch1-s0"])
        // First sub-section of the open chapter: header prepended, then its block.
        #expect(display[1].items.map(\.id) == ["ch-0", "b-c0-a"])
        #expect(display[2].items.map(\.id) == ["b-c0-b"])  // s1: content only, no header
        #expect(display[3].items.map(\.id) == ["ch-1"])  // chapter 1 still collapsed
    }
}
