// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ChapterLabelTests {
    @Test func narratedAndAuthoredTitlesShareOneName() {
        #expect(ChapterLabel.name("ch. 1: A Sad Part") == "A Sad Part")
        #expect(ChapterLabel.name("1. A Sad Part") == "A Sad Part")
        #expect(ChapterLabel.name("Chapter 12 - The Bridge") == "The Bridge")
    }

    @Test func keepsTitlesThatAreNotNumberPrefixed() {
        #expect(ChapterLabel.name("1984") == "1984")
        #expect(ChapterLabel.name("Chapter 3") == "Chapter 3")
        #expect(ChapterLabel.name("Chapter One: The Door") == "Chapter One: The Door")
        #expect(ChapterLabel.name("Prologue") == "Prologue")
    }

    @Test func keepsANumberThatIsPartOfTheName() {
        #expect(ChapterLabel.name("24 Hours in Paris") == "24 Hours in Paris")
        #expect(ChapterLabel.name("101 Dalmatians") == "101 Dalmatians")
        #expect(ChapterLabel.name("3 Days Later") == "3 Days Later")
        #expect(ChapterLabel.name("01 - A Door Opens") == "A Door Opens")
    }

    @Test func keepsPartLabelsWhole() {
        #expect(ChapterLabel.name("Part 2: The Return") == "Part 2: The Return")
        #expect(ChapterLabel.name("Pt 1 - Arrival") == "Pt 1 - Arrival")
    }

    @Test func fallbackSpellsOutChapter() {
        #expect(ChapterLabel.fallback(index: 0) == "Chapter 1")
        #expect(ChapterLabel.fallback(index: 19) == "Chapter 20")
    }

    @Test func headlineUsesChapterNameInChapteredBooks() {
        let headline = ChapterLabel.headline(
            chapterCount: 20, chapterTitle: "ch. 1: A Sad Part", chapterIndex: 0, trackTitle: "merchant.m4b")
        #expect(headline == "A Sad Part")
    }

    @Test func headlineFallsBackToChapterNumberWhenUntitled() {
        let headline = ChapterLabel.headline(
            chapterCount: 3, chapterTitle: "", chapterIndex: 1, trackTitle: "merchant.m4b")
        #expect(headline == "Chapter 2")
    }

    @Test func headlineUsesTrackTitleWithoutChapters() {
        let headline = ChapterLabel.headline(
            chapterCount: 1, chapterTitle: "ch. 1: A Sad Part", chapterIndex: 0, trackTitle: "The Merchant")
        #expect(headline == "The Merchant")
    }
}
