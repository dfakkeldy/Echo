// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// The headless m4b export must title chapters from their EPUB headings, keyed by
/// the raw chapter index (never file position), so chapter markers carry real names.
@Suite struct HeadlessNarrationExportTitlesTests {

    @Test func mapsExportTitlesFromHeadingsByChapterIndex() {
        let outline = [
            NarrationOutlineChapter(
                chapterIndex: 0, displayNumber: 1, title: "Introduction",
                isExcluded: false, isRendered: true),
            // A gap in chapterIndex (1 excluded/absent) must not shift the mapping.
            NarrationOutlineChapter(
                chapterIndex: 2, displayNumber: 2, title: "The Cat Ate My Source Code",
                isExcluded: false, isRendered: true),
        ]
        let titles = HeadlessNarrationRunner.titlesByChapterIndex(outline)
        #expect(titles[0] == "Introduction")
        #expect(titles[2] == "The Cat Ate My Source Code")
        #expect(titles[1] == nil)
    }
}
