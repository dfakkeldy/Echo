// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

struct BookProgressTrackModelTests {
    private func chapter(_ index: Int, start: Double, end: Double) -> Chapter {
        Chapter(index: index, title: "Ch \(index + 1)", startSeconds: start, endSeconds: end)
    }

    @Test func tickFractionsAreInteriorChapterStarts() {
        let chapters = [
            chapter(0, start: 0, end: 100),
            chapter(1, start: 100, end: 300),
            chapter(2, start: 300, end: 400),
        ]
        let fractions = BookProgressTrackModel.tickFractions(chapters: chapters, totalDuration: 400)
        #expect(fractions == [0.25, 0.75])  // chapter 0's start (0.0) is skipped
    }

    @Test func tickFractionsEmptyWhenNoDuration() {
        #expect(BookProgressTrackModel.tickFractions(chapters: [], totalDuration: 0).isEmpty)
    }

    @Test func captionMatchesMockFormat() {
        let caption = BookProgressTrackModel.caption(
            bookFraction: 0.04, chapterTitle: "Prologue", chapterCount: 8
        )
        #expect(caption == "4% of book · Prologue of 8 chapters")
    }

    @Test func captionOmitsChapterPartWhenSingleChapter() {
        let caption = BookProgressTrackModel.caption(bookFraction: 0.5, chapterTitle: nil, chapterCount: 1)
        #expect(caption == "50% of book")
    }
}
