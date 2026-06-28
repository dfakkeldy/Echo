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
                title: titlePreservingDuplicatePrefixPunctuation(for: planned),
                isExcluded: isExcluded,
                isRendered: isRendered(planned.index))
        }
    }

    private static func titlePreservingDuplicatePrefixPunctuation(
        for planned: NarrationChapterPlanner.PlannedChapter
    ) -> String {
        let titlePrefix = "ch. \(planned.displayNumber): "
        guard planned.title.hasPrefix(titlePrefix),
            let headingTitle = duplicatePrefixHeadingTitle(
                displayNumber: planned.displayNumber, blocks: planned.blocks)
        else { return planned.title }

        let plannedHeadingTitle = String(planned.title.dropFirst(titlePrefix.count))
        guard headingTitle == plannedHeadingTitle || headingTitle.hasPrefix(plannedHeadingTitle)
        else { return planned.title }

        return "\(titlePrefix)\(headingTitle)"
    }

    private static func duplicatePrefixHeadingTitle(
        displayNumber: Int,
        blocks: [EPubBlockRecord]
    ) -> String? {
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
            if let title = strippedDuplicatePrefixTitle(
                from: heading, displayNumber: displayNumber)
            {
                return title
            }
        }
        return nil
    }

    private static func strippedDuplicatePrefixTitle(
        from heading: String,
        displayNumber: Int
    ) -> String? {
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

            let stripped = String(suffix.drop(while: isTitleBoundary))
            guard !stripped.isEmpty,
                !isGenericChapterLabel(stripped, displayNumber: displayNumber)
            else { return nil }
            return stripped
        }
        return nil
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

    private static func isTitleBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { titleSeparatorCharacters.contains($0) }
    }

    private static var titleSeparatorCharacters: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: ":.-)–—")
        return set
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
}
