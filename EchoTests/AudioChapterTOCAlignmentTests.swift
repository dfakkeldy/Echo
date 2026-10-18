// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Chaptering for an audiobook that carries chapter marks *and* ships a
/// publisher EPUB. The import fallback estimates each block's audio position
/// from cumulative word count, which assumes a uniform narration rate and
/// therefore drifts — boundaries land mid-paragraph and every chapter straddles
/// two spine items. When the audio chapter titles and the TOC labels describe
/// the same structure, the TOC already knows each chapter's exact first block.
struct AudioChapterTOCAlignmentTests {

    private func blk(_ id: String, seq: Int, spine: Int, frontMatter: Bool = false)
        -> EPubBlockRecord
    {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "s\(spine).xhtml",
            spineIndex: spine, blockIndex: 0, sequenceIndex: seq,
            blockKind: "paragraph", isHidden: false, isFrontMatter: frontMatter)
    }

    private func toc(_ title: String, block: String?, order: Int) -> EPubTOCEntryRecord {
        EPubTOCEntryRecord(
            id: "toc-\(order)", audiobookID: "bk", parentID: nil, orderIndex: order,
            depth: 0, title: title, blockID: block, spineIndex: nil)
    }

    private func audio(_ pairs: [(Int, String?)]) -> [AudioChapterTOCAlignment.AudioChapter] {
        pairs.map { AudioChapterTOCAlignment.AudioChapter(index: $0.0, title: $0.1) }
    }

    /// The shape of a real commercial audiobook + retail EPUB pairing: credits
    /// marks with no text behind them, front matter the TOC lists but the audio
    /// never names, and body chapters whose labels match exactly.
    @Test func matchingLabelsGiveExactBoundaries() {
        let blocks = [
            blk("b0", seq: 0, spine: 0, frontMatter: true),  // title page
            blk("b1", seq: 1, spine: 1),  // contents
            blk("b2", seq: 2, spine: 1),
            blk("b3", seq: 3, spine: 2),  // prologue
            blk("b4", seq: 4, spine: 2),
            blk("b5", seq: 5, spine: 3),  // chapter 1
            blk("b6", seq: 6, spine: 3),
            blk("b7", seq: 7, spine: 4),  // chapter 2
            blk("b8", seq: 8, spine: 5),  // photo insert
        ]
        let entries = [
            toc("Title Page", block: "b0", order: 0),
            toc("Contents", block: "b1", order: 1),
            toc("Prologue", block: "b3", order: 2),
            toc("1: Her Majesty\u{2019}s Story", block: "b5", order: 3),  // curly
            toc("2: Courtroom 3: Application for Bail", block: "b7", order: 4),
            toc("Photo Insert", block: "b8", order: 5),
        ]
        let chapters = audio([
            (0, "Opening Credits"),
            (1, "Prologue"),
            (2, "1: Her Majesty's Story"),  // straight apostrophe
            (3, "2: Courtroom 3: Application for Bail"),
            (4, "End Credits"),
        ])

        let result = AudioChapterTOCAlignment.chapterIndices(
            blocks: blocks, tocEntries: entries, audioChapters: chapters)

        #expect(result?["b0"] == nil)  // front matter stays unassigned
        #expect(result?["b1"] == 0)  // ahead of the first boundary → credits
        #expect(result?["b2"] == 0)
        #expect(result?["b3"] == 1)  // exactly at the TOC's Prologue anchor
        #expect(result?["b4"] == 1)
        #expect(result?["b5"] == 2)
        #expect(result?["b6"] == 2)
        #expect(result?["b7"] == 3)
        #expect(result?["b8"] == 3)  // no audio mark of its own → stays in 3
    }

    /// A single incidental label collision must not re-chapter a whole book;
    /// the caller's word-count estimate is the safer answer.
    @Test func tooFewMatchesFallsBack() {
        let blocks = (0..<6).map { blk("b\($0)", seq: $0, spine: $0) }
        let entries = [
            toc("Prologue", block: "b1", order: 0),
            toc("Something Else Entirely", block: "b3", order: 1),
        ]
        let chapters = audio([
            (0, "Opening Credits"), (1, "Prologue"), (2, "Track 3"),
            (3, "Track 4"), (4, "Track 5"), (5, "End Credits"),
        ])

        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: blocks, tocEntries: entries, audioChapters: chapters) == nil)
    }

    /// Two matches out of six is agreement by neither count nor majority.
    @Test func minorityAgreementFallsBack() {
        let blocks = (0..<6).map { blk("b\($0)", seq: $0, spine: $0) }
        let entries = [
            toc("Prologue", block: "b1", order: 0),
            toc("Epilogue", block: "b4", order: 1),
        ]
        let chapters = audio([
            (0, "Prologue"), (1, "Track 2"), (2, "Track 3"),
            (3, "Track 4"), (4, "Epilogue"), (5, "End Credits"),
        ])

        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: blocks, tocEntries: entries, audioChapters: chapters) == nil)
    }

    /// When the first audio chapter itself matches, nothing precedes it, so
    /// leading body blocks stay unassigned rather than being folded backwards.
    @Test func noChapterPrecedesTheFirstBoundary() {
        let blocks = [
            blk("b0", seq: 0, spine: 0),
            blk("b1", seq: 1, spine: 1),
            blk("b2", seq: 2, spine: 2),
        ]
        let entries = [
            toc("One", block: "b1", order: 0),
            toc("Two", block: "b2", order: 1),
        ]
        let chapters = audio([(0, "One"), (1, "Two")])

        let result = AudioChapterTOCAlignment.chapterIndices(
            blocks: blocks, tocEntries: entries, audioChapters: chapters)

        #expect(result?["b0"] == nil)
        #expect(result?["b1"] == 0)
        #expect(result?["b2"] == 1)
    }

    /// A label that recurs (a per-part "Interlude") is consumed in reading
    /// order, so the second audio mark takes the second TOC entry rather than
    /// re-matching the first and collapsing the boundaries.
    @Test func repeatedLabelsConsumeForward() {
        let blocks = (0..<4).map { blk("b\($0)", seq: $0, spine: $0) }
        let entries = [
            toc("Interlude", block: "b1", order: 0),
            toc("Interlude", block: "b3", order: 1),
        ]
        let chapters = audio([(0, "Interlude"), (1, "Interlude")])

        let result = AudioChapterTOCAlignment.chapterIndices(
            blocks: blocks, tocEntries: entries, audioChapters: chapters)

        #expect(result?["b1"] == 0)
        #expect(result?["b2"] == 0)
        #expect(result?["b3"] == 1)
    }

    @Test func emptyInputsFallBack() {
        let blocks = [blk("b0", seq: 0, spine: 0)]
        let entries = [toc("One", block: "b0", order: 0)]

        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: blocks, tocEntries: entries, audioChapters: []) == nil)
        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: blocks, tocEntries: [], audioChapters: audio([(0, "One")])) == nil)
        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: [], tocEntries: entries, audioChapters: audio([(0, "One")])) == nil)
    }

    /// Untitled marks cannot match, and the majority gate counts them, so a
    /// book whose audio metadata carries no names falls back.
    @Test func untitledAudioChaptersFallBack() {
        let blocks = (0..<4).map { blk("b\($0)", seq: $0, spine: $0) }
        let entries = [
            toc("One", block: "b1", order: 0),
            toc("Two", block: "b3", order: 1),
        ]
        let chapters = audio([(0, nil), (1, nil), (2, nil), (3, nil), (4, nil)])

        #expect(
            AudioChapterTOCAlignment.chapterIndices(
                blocks: blocks, tocEntries: entries, audioChapters: chapters) == nil)
    }
}
