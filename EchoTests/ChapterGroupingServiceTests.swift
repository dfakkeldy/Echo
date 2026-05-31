import XCTest
@testable import Echo

final class ChapterGroupingServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a mock Chapter with the given title spanning [start, end) seconds.
    private func ch(_ title: String, start: Double, end: Double, index: Int = 0) -> Chapter {
        Chapter(index: index, title: title, startSeconds: start, endSeconds: end)
    }

    // MARK: - logicalBaseTitle

    func testBaseTitleStripsLetterSuffix() {
        XCTAssertEqual(
            ChapterGroupingService.logicalBaseTitle(for: "Chapter 11. A"),
            "Chapter 11"
        )
        XCTAssertEqual(
            ChapterGroupingService.logicalBaseTitle(for: "Part III. Trust and Autonomy: Chapter 11. B"),
            "Part III. Trust and Autonomy: Chapter 11"
        )
    }

    func testBaseTitleStripsNumericSuffix() {
        XCTAssertEqual(
            ChapterGroupingService.logicalBaseTitle(for: "Chapter 4. 12"),
            "Chapter 4"
        )
    }

    func testBaseTitleDoesNotStripNormalTitle() {
        let title = "Introduction"
        XCTAssertEqual(ChapterGroupingService.logicalBaseTitle(for: title), title)
    }

    func testBaseTitleDoesNotStripMidSentenceLetters() {
        // Only a TRAILING ". A" should be stripped, not an embedded one.
        let title = "Part A. Chapter 3"
        XCTAssertEqual(ChapterGroupingService.logicalBaseTitle(for: title), title)
    }

    // MARK: - Grouping: Libation pattern

    func testLibationPatternGrouped() {
        // Simulate Libation sub-section atoms for two chapters.
        let chapters = [
            ch("Part I. Foundations. A",   start: 0,    end: 120,  index: 0),
            ch("Part I. Foundations. B",   start: 120,  end: 240,  index: 1),
            ch("Part I. Foundations. C",   start: 240,  end: 360,  index: 2),
            ch("Part II. Practice. A",     start: 360,  end: 500,  index: 3),
            ch("Part II. Practice. B",     start: 500,  end: 620,  index: 4),
        ]

        let result = ChapterGroupingService.group(chapters)

        XCTAssertTrue(result.wasGrouped)
        // Should collapse to 2 logical chapters.
        XCTAssertEqual(result.logicalChapters.count, 2)

        // First logical chapter spans full range of its sub-sections.
        let first = result.logicalChapters[0]
        XCTAssertEqual(first.title, "Part I. Foundations")
        XCTAssertEqual(first.startSeconds, 0)
        XCTAssertEqual(first.endSeconds, 360)

        // Second logical chapter.
        let second = result.logicalChapters[1]
        XCTAssertEqual(second.title, "Part II. Practice")
        XCTAssertEqual(second.startSeconds, 360)
        XCTAssertEqual(second.endSeconds, 620)

        // Sections map should contain the original atoms.
        XCTAssertEqual(result.sections[0]?.count, 3) // 3 atoms for Part I
        XCTAssertEqual(result.sections[1]?.count, 2) // 2 atoms for Part II
    }

    func testHierarchicalPatternGrouped() {
        let chapters = [
            ch("Chapter 1: Intro", start: 0, end: 10, index: 0),
            ch("Chapter 1: Intro: Setup", start: 10, end: 20, index: 1),
            ch("Chapter 1: Intro: Basics", start: 20, end: 30, index: 2),
            ch("Chapter 2", start: 30, end: 40, index: 3),
            ch("Chapter 2: Advanced", start: 40, end: 50, index: 4)
        ]

        let result = ChapterGroupingService.group(chapters)

        XCTAssertTrue(result.wasGrouped)
        XCTAssertEqual(result.logicalChapters.count, 2)

        let first = result.logicalChapters[0]
        XCTAssertEqual(first.title, "Chapter 1: Intro")
        XCTAssertEqual(first.startSeconds, 0)
        XCTAssertEqual(first.endSeconds, 30)

        let second = result.logicalChapters[1]
        XCTAssertEqual(second.title, "Chapter 2")
        XCTAssertEqual(second.startSeconds, 30)
        XCTAssertEqual(second.endSeconds, 50)

        XCTAssertEqual(result.sections[0]?.count, 3)
        XCTAssertEqual(result.sections[1]?.count, 2)
    }

    func testGroupedChaptersHaveCorrectIndices() {
        let chapters = [
            ch("Chapter 1. A", start: 0,   end: 60,  index: 0),
            ch("Chapter 1. B", start: 60,  end: 120, index: 1),
            ch("Chapter 2. A", start: 120, end: 180, index: 2),
            ch("Chapter 2. B", start: 180, end: 240, index: 3),
        ]

        let result = ChapterGroupingService.group(chapters)

        XCTAssertTrue(result.wasGrouped)
        XCTAssertEqual(result.logicalChapters[0].index, 0)
        XCTAssertEqual(result.logicalChapters[1].index, 1)
    }

    // MARK: - Grouping: No grouping needed (OpenAudible / coarse chapters)

    func testUniformTitlesNotGrouped() {
        let chapters = [
            ch("Who This Book Is For",        start: 0,    end: 578,   index: 0),
            ch("Preface",                     start: 578,  end: 629,   index: 1),
            ch("Part I. Foundations",         start: 629,  end: 10457, index: 2),
            ch("Part II. AI Coding in Prac.", start: 10457, end: 21664, index: 3),
        ]

        let result = ChapterGroupingService.group(chapters)

        XCTAssertFalse(result.wasGrouped)
        // Logical chapters should equal the original input.
        XCTAssertEqual(result.logicalChapters.count, chapters.count)
        XCTAssertTrue(result.sections.isEmpty)
    }

    // MARK: - Mixed pattern (some groups, some singletons)

    func testMixedPatternGroupsOnly_groupedAtoms() {
        let chapters = [
            ch("Opening Credits",    start: 0,   end: 20,  index: 0),  // singleton
            ch("Chapter 1. A",       start: 20,  end: 80,  index: 1),  // }
            ch("Chapter 1. B",       start: 80,  end: 140, index: 2),  // } group
            ch("End Credits",        start: 140, end: 160, index: 3),  // singleton
        ]

        let result = ChapterGroupingService.group(chapters)

        XCTAssertTrue(result.wasGrouped)
        // 4 atoms → 3 logical: "Opening Credits", "Chapter 1", "End Credits"
        XCTAssertEqual(result.logicalChapters.count, 3)
        XCTAssertEqual(result.logicalChapters[1].title, "Chapter 1")
        XCTAssertEqual(result.logicalChapters[1].startSeconds, 20)
        XCTAssertEqual(result.logicalChapters[1].endSeconds, 140)

        // Only the grouped chapter has a sections entry.
        XCTAssertNil(result.sections[0])  // "Opening Credits" had no siblings
        XCTAssertEqual(result.sections[1]?.count, 2)
        XCTAssertNil(result.sections[2])  // "End Credits" had no siblings
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsEmpty() {
        let result = ChapterGroupingService.group([])
        XCTAssertFalse(result.wasGrouped)
        XCTAssertTrue(result.logicalChapters.isEmpty)
        XCTAssertTrue(result.sections.isEmpty)
    }

    func testSingleChapterNotGrouped() {
        let result = ChapterGroupingService.group([ch("Only Chapter", start: 0, end: 3600)])
        XCTAssertFalse(result.wasGrouped)
        XCTAssertEqual(result.logicalChapters.count, 1)
    }

    func testIsEnabledPreservedInLogicalChapter() {
        // All sub-sections enabled → logical chapter enabled.
        let chapters = [
            Chapter(index: 0, title: "Ch 1. A", startSeconds: 0,  endSeconds: 60,  isEnabled: true),
            Chapter(index: 1, title: "Ch 1. B", startSeconds: 60, endSeconds: 120, isEnabled: true),
        ]
        let result = ChapterGroupingService.group(chapters)
        XCTAssertTrue(result.logicalChapters[0].isEnabled)
    }

    func testIsEnabledFalseWhenAnySectionDisabled() {
        // One sub-section disabled → logical chapter disabled.
        let chapters = [
            Chapter(index: 0, title: "Ch 1. A", startSeconds: 0,  endSeconds: 60,  isEnabled: true),
            Chapter(index: 1, title: "Ch 1. B", startSeconds: 60, endSeconds: 120, isEnabled: false),
        ]
        let result = ChapterGroupingService.group(chapters)
        XCTAssertFalse(result.logicalChapters[0].isEnabled)
    }
}
