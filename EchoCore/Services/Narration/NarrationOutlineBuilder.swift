// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One row of the narration chapter outline shown on the playlist page.
struct NarrationOutlineChapter: Identifiable, Equatable {
    /// Raw EPUB chapter index — stable identity, keys the cache file + track id.
    let chapterIndex: Int
    /// 1-based position among narratable chapters (does NOT shift on exclude).
    let displayNumber: Int
    /// Heading-derived title, else "Chapter <displayNumber>".
    let title: String
    /// Every block in the chapter is hidden → not narrated.
    let isExcluded: Bool
    /// A rendered audio file exists for this chapter.
    let isRendered: Bool
    var id: Int { chapterIndex }
}

/// Builds the full narration outline from a book's EPUB blocks. Pure (no DB / no
/// filesystem) — `isRendered` is injected — so it is unit-testable in isolation,
/// mirroring `NarrationChapterPlanner`. Passes ALL blocks (not `visibleBlocks`) so
/// a fully-excluded chapter still appears, greyed, and can be re-included.
enum NarrationOutlineBuilder {
    static func build(
        allBlocks: [EPubBlockRecord], isRendered: (Int) -> Bool
    ) -> [NarrationOutlineChapter] {
        NarrationChapterPlanner.plan(from: allBlocks).map { planned in
            let ordered = planned.blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
            let isExcluded = ordered.allSatisfy { $0.isHidden }
            return NarrationOutlineChapter(
                chapterIndex: planned.index,
                displayNumber: planned.displayNumber,
                title: planned.title,
                isExcluded: isExcluded,
                isRendered: isRendered(planned.index))
        }
    }
}

nonisolated enum NarrationOutlineReadiness {
    static func renderedChapterIndices(
        expectedFileNamesByChapter: [Int: Set<String>],
        existingFileNames: Set<String>
    ) -> Set<Int> {
        Set(expectedFileNamesByChapter.compactMap { chapterIndex, expectedFileNames in
            guard !expectedFileNames.isEmpty,
                expectedFileNames.isSubset(of: existingFileNames)
            else { return nil }
            return chapterIndex
        })
    }

    static func removableQueueIndices(
        fileNames: [String],
        currentIndex: Int,
        expectedFileNames: Set<String>
    ) -> [Int] {
        fileNames.indices.reversed().filter { index in
            index != currentIndex && expectedFileNames.contains(fileNames[index])
        }
    }
}
