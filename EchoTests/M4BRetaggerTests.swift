// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// `M4BRetagger` re-stamps an existing m4b's chapter titles from the EPUB headings
/// while keeping the existing chapter *times* — count-tolerant when the EPUB and the
/// rendered m4b disagree on chapter count.
@Suite struct M4BRetaggerTests {

    @Test func keepsTimesAndAppliesNewTitlesInOrder() {
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 12.5, 30],
            newTitles: ["Introduction", "The Cat Ate It", "Outro"],
            fallback: ["Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(atoms.map(\.startTime) == [0, 12.5, 30])
        #expect(atoms.map(\.title) == ["Introduction", "The Cat Ate It", "Outro"])
    }

    @Test func fallsBackToExistingTitleWhenFewerNewTitles() {
        // m4b has 3 chapters but the EPUB only yielded 2 heading titles: keep all 3
        // times, fall back to the m4b's own title for the unmatched chapter.
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 10, 20],
            newTitles: ["Intro", "Body"],
            fallback: ["old-1", "old-2", "old-3"])
        #expect(atoms.count == 3)
        #expect(atoms.map(\.title) == ["Intro", "Body", "old-3"])
    }

    @Test func extraNewTitlesAreDropped() {
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 10], newTitles: ["A", "B", "C", "D"], fallback: [])
        #expect(atoms.map(\.title) == ["A", "B"])
    }
}
