// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Chapter header naming shared by the iOS and macOS readers. Deriving a title
/// from the chapter's first heading block reads a Calibre-converted chapter as
/// its number alone — the opener is `<h1>2</h1>` followed by
/// `<h1>COURTROOM 3: …</h1>` — so the publisher's own label has to win.
struct ChapterTitleResolverTests {

    private func toc(_ title: String, block: String?, order: Int) -> EPubTOCEntryRecord {
        EPubTOCEntryRecord(
            id: "toc-\(order)", audiobookID: "bk", parentID: nil, orderIndex: order,
            depth: 0, title: title, blockID: block, spineIndex: nil)
    }

    @Test func publisherTOCLabelWinsOverAudioMetadata() {
        let titles = ChapterTitleResolver.titles(
            firstBlockIDByChapter: [0: "b0", 1: "b5"],
            tocEntries: [
                toc("Prologue", block: "b0", order: 0),
                toc("1: Her Majesty\u{2019}s Story", block: "b5", order: 1),
            ],
            audioChapterTitles: [0: "Track 01", 1: "Track 02"])

        #expect(titles[0] == "Prologue")
        #expect(titles[1] == "1: Her Majesty\u{2019}s Story")
    }

    @Test func audioTitleFillsInWhenNoTOCEntryAnchorsTheChapter() {
        let titles = ChapterTitleResolver.titles(
            firstBlockIDByChapter: [0: "b0", 1: "b5"],
            tocEntries: [toc("Prologue", block: "b0", order: 0)],
            audioChapterTitles: [0: "Opening Credits", 1: "1: Her Majesty's Story"])

        #expect(titles[0] == "Prologue")
        #expect(titles[1] == "1: Her Majesty's Story")
    }

    /// A chapter the TOC does not anchor and the audio does not name is left
    /// absent, so the caller's own fallback ("Chapter N", or the first heading)
    /// still applies.
    @Test func unnamedChapterIsAbsent() {
        let titles = ChapterTitleResolver.titles(
            firstBlockIDByChapter: [0: "b0", 7: "b90"],
            tocEntries: [toc("Prologue", block: "b0", order: 0)],
            audioChapterTitles: [:])

        #expect(titles[0] == "Prologue")
        #expect(titles[7] == nil)
    }

    @Test func blankTitlesAreIgnoredInBothSources() {
        let titles = ChapterTitleResolver.titles(
            firstBlockIDByChapter: [0: "b0", 1: "b5"],
            tocEntries: [
                toc("   ", block: "b0", order: 0),
                toc("\n", block: "b5", order: 1),
            ],
            audioChapterTitles: [0: "Opening Credits", 1: "  "])

        #expect(titles[0] == "Opening Credits")  // blank TOC label → audio
        #expect(titles[1] == nil)  // both blank → caller's fallback
    }

    /// Entries with no resolved block cannot name anything, and the first
    /// entry anchored to a block wins if a later one repeats the anchor.
    @Test func unresolvedAndDuplicateAnchors() {
        let titles = ChapterTitleResolver.titles(
            firstBlockIDByChapter: [0: "b0"],
            tocEntries: [
                toc("Dangling", block: nil, order: 0),
                toc("Prologue", block: "b0", order: 1),
                toc("Prologue (again)", block: "b0", order: 2),
            ],
            audioChapterTitles: [:])

        #expect(titles[0] == "Prologue")
    }
}
