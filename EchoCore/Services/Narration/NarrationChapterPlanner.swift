// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns a book's EPUB blocks into the ordered list of chapters that on-device
/// narration should render and play, one rendered file (and pipeline track) per
/// chapter. Pure logic so it can be unit-tested without the TTS engine.
enum NarrationChapterPlanner {

    /// One narratable chapter: its raw EPUB chapter index (stable identity — keys
    /// the cache filename, track id, and resume lookup), a 1-based `displayNumber`
    /// for the human-facing title (position among *narratable* chapters, so the
    /// first real chapter reads "Chapter 1" even when front matter occupies EPUB
    /// indices 0…2), a heading-derived `title`, and the blocks to synthesize in
    /// reading (sequence) order.
    struct PlannedChapter: Equatable {
        let index: Int
        let displayNumber: Int
        let title: String
        let blocks: [EPubBlockRecord]

        init(
            index: Int,
            displayNumber: Int,
            blocks: [EPubBlockRecord],
            title: String? = nil
        ) {
            self.index = index
            self.displayNumber = displayNumber
            self.blocks = blocks
            self.title = title
                ?? NarrationChapterPlanner.title(displayNumber: displayNumber, blocks: blocks)
        }
    }

    /// Groups `blocks` by chapter index, ascending. Blocks with no chapter index
    /// (front matter that wasn't mapped) are dropped, as are chapters with no
    /// spoken text (image-only or empty), so narration never renders silent
    /// chapters. Within a chapter, blocks are returned in sequence order.
    ///
    /// `displayNumber` is assigned AFTER the empty-chapter filter, so dropped
    /// front matter / image-only sections don't leave gaps in the visible
    /// numbering — the surviving chapters are numbered 1, 2, 3… in order.
    static func plan(from blocks: [EPubBlockRecord]) -> [PlannedChapter] {
        let grouped = Dictionary(grouping: blocks.filter { $0.chapterIndex != nil }) {
            $0.chapterIndex!
        }
        let narratable = grouped.keys.sorted().compactMap { index -> (Int, [EPubBlockRecord])? in
            let chapterBlocks = grouped[index]!.sorted { $0.sequenceIndex < $1.sequenceIndex }
            guard chapterBlocks.contains(where: { ($0.text?.isEmpty == false) }) else { return nil }
            return (index, chapterBlocks)
        }
        return narratable.enumerated().map { offset, entry in
            PlannedChapter(index: entry.0, displayNumber: offset + 1, blocks: entry.1)
        }
    }

    /// Returns a persisted/display chapter title like "ch. 1: The Door Opens".
    /// Generic chapter-only headings are ignored so title-only secondary headings
    /// can supply the useful part; if no useful heading exists, keep the existing
    /// "Chapter N" fallback.
    static func title(displayNumber: Int, blocks: [EPubBlockRecord]) -> String {
        let fallback = "Chapter \(displayNumber)"
        let headings = blocks
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
            .compactMap { block -> String? in
                guard EPubBlockRecord.Kind(rawValue: block.blockKind) == .heading,
                    let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return nil }
                return text
            }

        for heading in headings {
            if let headingTitle = meaningfulHeadingTitle(
                from: heading, displayNumber: displayNumber)
            {
                return "ch. \(displayNumber): \(headingTitle)"
            }
        }
        return fallback
    }

    private static func meaningfulHeadingTitle(
        from heading: String,
        displayNumber: Int
    ) -> String? {
        let stripped = strippedDuplicatePrefix(from: heading, displayNumber: displayNumber)
            .trimmingCharacters(in: titleSeparatorCharacters)
        guard !stripped.isEmpty, !isGenericChapterLabel(stripped, displayNumber: displayNumber)
        else { return nil }
        return stripped
    }

    private static func strippedDuplicatePrefix(
        from heading: String,
        displayNumber: Int
    ) -> String {
        var prefixes = [
            "chapter \(displayNumber)",
            "ch. \(displayNumber)",
            "ch \(displayNumber)",
            "\(displayNumber)",
        ]
        if let word = englishCardinal(displayNumber) {
            prefixes.append("chapter \(word)")
            prefixes.append("ch. \(word)")
            prefixes.append("ch \(word)")
        }
        if let roman = romanNumeral(displayNumber)?.lowercased() {
            prefixes.append("chapter \(roman)")
            prefixes.append("ch. \(roman)")
            prefixes.append("ch \(roman)")
        }

        for prefix in prefixes {
            guard
                let range = heading.range(
                    of: prefix,
                    options: [.caseInsensitive, .anchored])
            else { continue }

            let suffix = heading[range.upperBound...]
            guard suffix.first.map(isTitleBoundary) ?? true else { continue }
            return String(suffix)
        }
        return heading
    }

    private static func isGenericChapterLabel(_ title: String, displayNumber: Int) -> Bool {
        let normalized = normalizeLabel(title)
        var labels = [
            "chapter \(displayNumber)",
            "ch \(displayNumber)",
            "\(displayNumber)",
        ]
        if let word = englishCardinal(displayNumber) {
            labels.append("chapter \(word)")
            labels.append("ch \(word)")
            labels.append(word)
        }
        if let roman = romanNumeral(displayNumber)?.lowercased() {
            labels.append("chapter \(roman)")
            labels.append("ch \(roman)")
            labels.append(roman)
        }
        return labels.map(normalizeLabel).contains(normalized)
    }

    private static func normalizeLabel(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static var titleSeparatorCharacters: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: ":.-)–—")
        return set
    }

    private static func isTitleBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { titleSeparatorCharacters.contains($0) }
    }

    private static func englishCardinal(_ value: Int) -> String? {
        switch value {
        case 1: return "one"
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        case 5: return "five"
        case 6: return "six"
        case 7: return "seven"
        case 8: return "eight"
        case 9: return "nine"
        case 10: return "ten"
        case 11: return "eleven"
        case 12: return "twelve"
        case 13: return "thirteen"
        case 14: return "fourteen"
        case 15: return "fifteen"
        case 16: return "sixteen"
        case 17: return "seventeen"
        case 18: return "eighteen"
        case 19: return "nineteen"
        case 20: return "twenty"
        default: return nil
        }
    }

    private static func romanNumeral(_ value: Int) -> String? {
        guard value > 0, value < 40 else { return nil }
        let numerals = [
            (10, "X"),
            (9, "IX"),
            (5, "V"),
            (4, "IV"),
            (1, "I"),
        ]
        var remaining = value
        var result = ""
        for (amount, numeral) in numerals {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }

    /// The chapters at or after `resumeIndex`, ascending — the part that renders
    /// and plays first on resume. Unknown index → the unchanged plan (play from
    /// the start). This is the *forward* set; `beforeResume` returns the rest so
    /// the full book stays in the queue.
    static func resume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return chapters
        }
        return Array(chapters[pos...])
    }

    /// The chapters *before* `resumeIndex`, in **descending** order — rendered
    /// after the forward set and prepended to the queue so reopening a book keeps
    /// the FULL chapter list, not just the resume point onward (§5.3 / finish-plan
    /// Phase 4B), without a cold re-render of the whole book before playback can
    /// start. Empty when resuming at the first chapter or when `resumeIndex` is
    /// unknown. Descending so each rendered chapter can be cheaply prepended at
    /// index 0 and still land the queue in ascending chapter order.
    static func beforeResume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return []
        }
        return Array(chapters[..<pos].reversed())
    }
}
