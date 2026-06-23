// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ReaderFeedDisplayBuilder {

    /// Post-filters the Phase-1 grouped/accordion display sections by content type.
    ///
    /// Two granularities (Phase-3 Traps E/F/F2):
    /// - Chapter-level (`.audio`/`.text`): drop whole chapter GROUPS whose has-audio
    ///   flag doesn't match.
    /// - Block-level (`.pics`/`.picsAndAudio`): keep the chapter header but strip
    ///   non-matching blocks; a group left with only a header (no content blocks) is
    ///   dropped, since there's nothing to show under that filter.
    /// `.everything` is the identity. `.bookmarks`/`.cards` are pass-throughs until
    /// Phase 2 adds the matching `ReaderCardItem` cases.
    ///
    /// `chapterHasAudio` keys are audio chapter indices (`block.chapterIndex ?? -1`);
    /// front matter is `-1`. A missing key is treated as no-audio.
    public static func applyFilter(
        _ contentType: FeedContentType,
        to sections: [ReaderCardSection],
        chapterHasAudio: [Int: Bool]
    ) -> [ReaderCardSection] {
        guard contentType != .everything else { return sections }

        // Chapter-level: drop or keep whole groups by the section's chapter key.
        // Real API: chapterKey(forSectionID:) -> Int? (ReaderFeedDisplayBuilder.swift:25)
        if !contentType.isBlockLevel {
            return sections.filter { section in
                let key = chapterKey(forSectionID: section.id) ?? -1
                let audio = chapterHasAudio[key] ?? false
                return contentType.matchesChapter(hasAudio: audio)
            }
        }

        // Block-level: keep header, strip non-matching blocks, drop content-empty groups.
        var result: [ReaderCardSection] = []
        for section in sections {
            let key = chapterKey(forSectionID: section.id) ?? -1
            let audio = chapterHasAudio[key] ?? false

            var kept: [ReaderCardItem] = []
            var contentBlockCount = 0
            for item in section.items {
                switch item {
                case .chapterHeader:
                    kept.append(item)  // headers always survive (TOC structure)
                case .block(let block):
                    if contentType.matchesBlockKind(block.blockKind, hasAudio: audio) {
                        kept.append(item)
                        contentBlockCount += 1
                    }
                case .bookmark, .ankiCard, .note, .voiceMemo:
                    // Phase 2/4 items: pass-through under block-level filters.
                    kept.append(item)
                    contentBlockCount += 1
                }
            }

            // A surviving group must have at least one content block under this filter;
            // a header-only group is noise and gets dropped.
            if contentBlockCount > 0 {
                result.append(
                    ReaderCardSection(
                        id: section.id,
                        headingStack: section.headingStack,
                        items: kept))
            }
        }
        return result
    }
}
