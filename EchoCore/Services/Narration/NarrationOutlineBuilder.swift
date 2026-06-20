// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One row of the narration chapter outline shown on the playlist page.
struct NarrationOutlineChapter: Identifiable, Equatable {
    /// Raw EPUB chapter index — stable identity, keys the cache file + track id.
    let chapterIndex: Int
    /// 1-based position among narratable chapters (does NOT shift on exclude).
    let displayNumber: Int
    /// First heading-block text in the chapter, else "Chapter <displayNumber>".
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
            let title =
                ordered.first(where: {
                    EPubBlockRecord.Kind(rawValue: $0.blockKind) == .heading
                        && ($0.text?.isEmpty == false)
                })?.text ?? "Chapter \(planned.displayNumber)"
            let isExcluded = ordered.allSatisfy { $0.isHidden }
            return NarrationOutlineChapter(
                chapterIndex: planned.index,
                displayNumber: planned.displayNumber,
                title: title,
                isExcluded: isExcluded,
                isRendered: isRendered(planned.index))
        }
    }
}
