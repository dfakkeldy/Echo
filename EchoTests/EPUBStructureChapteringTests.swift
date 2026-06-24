// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Chaptering for books with no audio chapter markers (the m4b-without-chapters
/// and standalone-EPUB cases). Without this, every block stays `chapterIndex ==
/// nil`, which `blocksByChapter` coalesces to `-1` → one "Front Matter" chapter.
struct EPUBStructureChapteringTests {

    private func blk(_ id: String, seq: Int, spine: Int, frontMatter: Bool = false)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "s\(spine).xhtml",
            spineIndex: spine, blockIndex: 0, sequenceIndex: seq,
            blockKind: "paragraph", isHidden: false, isFrontMatter: frontMatter)
    }

    private func toc(_ id: String, block: String?, depth: Int, order: Int)
        -> EPubTOCEntryRecord
    {
        EPubTOCEntryRecord(
            id: id, audiobookID: "bk", parentID: nil, orderIndex: order,
            depth: depth, title: id, blockID: block, spineIndex: nil)
    }

    @Test func topLevelTOCEntriesBecomeChapters() {
        // Front matter b0, then two top-level TOC chapters starting at b1 and b3.
        let blocks = [
            blk("b0", seq: 0, spine: 0, frontMatter: true),
            blk("b1", seq: 1, spine: 1),
            blk("b2", seq: 2, spine: 1),
            blk("b3", seq: 3, spine: 2),
            blk("b4", seq: 4, spine: 2),
        ]
        let toc = [
            toc("Chapter One", block: "b1", depth: 0, order: 0),
            toc("Chapter Two", block: "b3", depth: 0, order: 1),
        ]

        let result = EPUBStructureChaptering.chapterIndices(blocks: blocks, tocEntries: toc)

        #expect(result["b0"] == nil)  // before the first chapter → front matter
        #expect(result["b1"] == 0)
        #expect(result["b2"] == 0)
        #expect(result["b3"] == 1)
        #expect(result["b4"] == 1)
    }

    @Test func chaptersByShallowestRepeatingDepth() {
        // A single "Part I" at depth 0 must not become the only chapter; the
        // three depth-1 chapters that actually repeat are the chapter level.
        let blocks = [
            blk("b0", seq: 0, spine: 0, frontMatter: true),
            blk("partI", seq: 1, spine: 1),
            blk("c1", seq: 2, spine: 1),
            blk("c1body", seq: 3, spine: 1),
            blk("c2", seq: 4, spine: 2),
            blk("c2body", seq: 5, spine: 2),
            blk("c3", seq: 6, spine: 3),
            blk("c3body", seq: 7, spine: 3),
        ]
        let toc = [
            toc("Part I", block: "partI", depth: 0, order: 0),
            toc("Chapter 1", block: "c1", depth: 1, order: 1),
            toc("Chapter 2", block: "c2", depth: 1, order: 2),
            toc("Chapter 3", block: "c3", depth: 1, order: 3),
        ]

        let result = EPUBStructureChaptering.chapterIndices(blocks: blocks, tocEntries: toc)

        #expect(result["b0"] == nil)
        #expect(result["partI"] == nil)  // sits before the first depth-1 boundary
        #expect(result["c1"] == 0)
        #expect(result["c1body"] == 0)
        #expect(result["c2"] == 1)
        #expect(result["c2body"] == 1)
        #expect(result["c3"] == 2)
        #expect(result["c3body"] == 2)
    }

    @Test func noTOCFallsBackToSpineNumbering() {
        // No declared TOC → number body spine items; front-matter spine stays nil.
        let blocks = [
            blk("b0", seq: 0, spine: 0, frontMatter: true),
            blk("b1", seq: 1, spine: 1),
            blk("b2", seq: 2, spine: 1),
            blk("b3", seq: 3, spine: 2),
        ]

        let result = EPUBStructureChaptering.chapterIndices(blocks: blocks, tocEntries: [])

        #expect(result["b0"] == nil)
        #expect(result["b1"] == 0)
        #expect(result["b2"] == 0)
        #expect(result["b3"] == 1)
    }

    @Test func allFrontMatterStillGetsAChapterZero() {
        // Degenerate book that is entirely front matter with no TOC: still number
        // the spines so there is a chapter 0 to read (mirrors prior import logic).
        let blocks = [
            blk("b0", seq: 0, spine: 0, frontMatter: true),
            blk("b1", seq: 1, spine: 1, frontMatter: true),
        ]

        let result = EPUBStructureChaptering.chapterIndices(blocks: blocks, tocEntries: [])

        #expect(result["b0"] == 0)
        #expect(result["b1"] == 1)
    }
}
