// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

struct ChapterPartGrouperTests {
    @Test func groupsConsecutiveSharedPartPrefixes() {
        let titles = [
            "Part One – The Meaning of Things: 1. Attractive Things Work Better",
            "Part One – The Meaning of Things: 2. The Multiple Faces of Emotion",
            "Part Two – Design in Practice: 3. Three Levels of Design",
            "Part Two – Design in Practice: 4. Fun and Games",
        ]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 2)
        #expect(groups[0].header == "Part One – The Meaning of Things")
        #expect(groups[0].rowTitles == ["1. Attractive Things Work Better", "2. The Multiple Faces of Emotion"])
        #expect(groups[1].header == "Part Two – Design in Practice")
        #expect(groups[1].rowTitles == ["3. Three Levels of Design", "4. Fun and Games"])
    }

    @Test func ungroupedTitlesYieldSingleHeaderlessGroup() {
        let titles = ["Prologue", "Chapter 1", "Chapter 2"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 1)
        #expect(groups[0].header == nil)
        #expect(groups[0].rowTitles == titles)
    }

    @Test func singleChapterUnderAPartIsNotGrouped() {
        // A "prefix" shared by only one chapter is not a part.
        let titles = ["Part One: Only Child", "Epilogue"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 1)
        #expect(groups[0].header == nil)
        #expect(groups[0].rowTitles == titles)
    }

    @Test func mixedPrefixedAndBareTitlesSplitCorrectly() {
        let titles = ["Prologue", "Part One: 1. A", "Part One: 2. B", "Epilogue"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 3)
        #expect(groups[0].header == nil)
        #expect(groups[0].rowTitles == ["Prologue"])
        #expect(groups[1].header == "Part One")
        #expect(groups[1].rowTitles == ["1. A", "2. B"])
        #expect(groups[2].header == nil)
        #expect(groups[2].rowTitles == ["Epilogue"])
    }
}
