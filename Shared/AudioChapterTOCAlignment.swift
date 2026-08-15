// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Aligns an audiobook's **audio chapter marks** to the publisher's declared
/// TOC so `epub_block.chapter_index` lands on real chapter boundaries.
///
/// The import fallback estimates a block's audio position from its cumulative
/// word count and assigns whichever audio chapter spans that estimate. That
/// assumes a uniform words-per-second rate across the whole book, which no real
/// audiobook has: opening/closing credits carry no text at all, and front
/// matter such as a contents list, timeline, or cast of characters is read at a
/// wildly different density from prose. The estimate therefore drifts, and
/// every chapter boundary lands mid-paragraph.
///
/// When the audio chapter titles and the TOC labels demonstrably describe the
/// same structure — the common case for a commercial audiobook paired with its
/// retail EPUB — the TOC already knows each chapter's exact first block, so
/// there is nothing to estimate. This type finds that correspondence and
/// returns `nil` when it cannot, leaving the caller's estimate in place.
///
/// Pure / Foundation-only so iOS, macOS, and the CLI import paths can share it.
enum AudioChapterTOCAlignment {
    /// One audio chapter mark, as much of it as alignment needs.
    struct AudioChapter: Equatable, Sendable {
        /// The index stored in `epub_block.chapter_index` for this chapter.
        let index: Int
        /// The chapter's title from audio metadata; nil when it carries none.
        let title: String?

        init(index: Int, title: String?) {
            self.index = index
            self.title = title
        }
    }

    /// `blockID` → audio chapter index, or `nil` when the TOC and the audio
    /// chapter list do not agree well enough to trust (see `isConfident`).
    ///
    /// Front-matter blocks are left unassigned so their `chapterIndex` stays
    /// `nil`, matching `EPUBStructureChaptering`'s convention. Body blocks
    /// ahead of the first matched boundary take the chapter immediately before
    /// it — that is where an untitled "Opening Credits" mark sits — and are
    /// left unassigned when no such chapter exists.
    static func chapterIndices(
        blocks: [EPubBlockRecord],
        tocEntries: [EPubTOCEntryRecord],
        audioChapters: [AudioChapter]
    ) -> [String: Int]? {
        guard !blocks.isEmpty, !tocEntries.isEmpty, !audioChapters.isEmpty else { return nil }

        let seqByBlockID = Dictionary(
            blocks.map { ($0.id, $0.sequenceIndex) }, uniquingKeysWith: { first, _ in first })
        let frontMatterBlockIDs = Set(blocks.lazy.filter(\.isFrontMatter).map(\.id))

        // TOC entries resolved to a concrete body block, in reading (preorder)
        // order. Front-matter targets are skipped for the same reason their
        // blocks are: a boundary there cannot start an audio chapter.
        let anchored: [(key: String, seq: Int)] = tocEntries.compactMap { entry in
            guard let blockID = entry.blockID,
                !frontMatterBlockIDs.contains(blockID),
                let seq = seqByBlockID[blockID]
            else { return nil }
            let key = matchKey(entry.title)
            return key.isEmpty ? nil : (key, seq)
        }
        guard !anchored.isEmpty else { return nil }

        guard let matches = matchedBoundaries(anchored: anchored, audioChapters: audioChapters),
            isConfident(matchCount: matches.count, audioChapterCount: audioChapters.count)
        else { return nil }

        // The chapter covering body text ahead of the first boundary — an
        // untitled credits mark, typically. Negative means there is none.
        let leadingChapter = matches[0].chapterIndex - 1

        var result: [String: Int] = [:]
        for block in blocks where !block.isFrontMatter {
            var chapter: Int? = leadingChapter >= 0 ? leadingChapter : nil
            for match in matches where match.seq <= block.sequenceIndex {
                chapter = match.chapterIndex
            }
            if let chapter { result[block.id] = chapter }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Matching

    /// Walks the audio chapters in index order, consuming TOC entries forward,
    /// so a repeated label (a "Part One" that recurs) can only ever match once
    /// and matches stay in reading order. Returns `nil` if the resulting
    /// boundaries are not strictly increasing — a TOC whose preorder disagrees
    /// with reading order is not one to chapter a book by.
    private static func matchedBoundaries(
        anchored: [(key: String, seq: Int)],
        audioChapters: [AudioChapter]
    ) -> [(chapterIndex: Int, seq: Int)]? {
        var matches: [(chapterIndex: Int, seq: Int)] = []
        var cursor = 0
        for chapter in audioChapters.sorted(by: { $0.index < $1.index }) {
            guard let title = chapter.title else { continue }
            let key = matchKey(title)
            guard !key.isEmpty, cursor < anchored.count else { continue }
            guard let hit = anchored[cursor...].firstIndex(where: { $0.key == key }) else {
                continue
            }
            matches.append((chapterIndex: chapter.index, seq: anchored[hit].seq))
            cursor = hit + 1
        }
        guard !matches.isEmpty else { return nil }
        for (previous, next) in zip(matches, matches.dropFirst()) where next.seq <= previous.seq {
            return nil
        }
        return matches
    }

    /// Requires at least two boundaries and a majority of the audio chapters to
    /// have found a label, so an incidental one-off collision ("Prologue"
    /// appearing in both lists of otherwise unrelated structures) cannot
    /// re-chapter a whole book.
    private static func isConfident(matchCount: Int, audioChapterCount: Int) -> Bool {
        matchCount >= 2 && matchCount * 2 >= audioChapterCount
    }

    /// Comparison key for a chapter label: lowercased, with everything but
    /// letters and digits removed. Retail EPUB and audio metadata routinely
    /// disagree on punctuation and case for the same chapter — a curly vs
    /// straight apostrophe in "Her Majesty's Story", an em dash vs a colon —
    /// while agreeing exactly on the words themselves.
    private static func matchKey(_ title: String) -> String {
        var key = ""
        for scalar in title.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key
    }
}
