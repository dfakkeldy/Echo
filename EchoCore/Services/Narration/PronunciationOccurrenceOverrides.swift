// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A single source-position pronunciation correction accepted from narration QA.
/// Word indices are the same whitespace-token indices used by `NarrationQADetector`.
struct PronunciationOccurrenceOverride: Codable, Equatable, Sendable {
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let word: String
    let ipa: String
}

/// Block-scoped pronunciation corrections for specific word positions. This is
/// intentionally separate from the global/book dictionary: it lets a reviewer fix
/// one ambiguous occurrence without changing every matching word in the book.
struct PronunciationOccurrenceOverrides: Equatable, Sendable {
    let entries: [PronunciationOccurrenceOverride]

    static let empty = PronunciationOccurrenceOverrides(entries: [])

    func apply(to text: String, blockID: String) -> String {
        let blockEntries = entries.filter { $0.blockID == blockID && !$0.ipa.isEmpty }
        guard !blockEntries.isEmpty else { return text }

        let wordRanges = WordTokenizer.wordRanges(in: text)
        guard !wordRanges.isEmpty else { return text }

        var claimedWordIndexes = Set<Int>()
        var replacements: [(range: NSRange, displayText: String, ipa: String)] = []
        for entry in blockEntries.sorted(by: sortSpecificEntriesFirst) {
            guard entry.wordStart >= 0,
                entry.wordEnd >= entry.wordStart,
                entry.wordEnd < wordRanges.count
            else {
                continue
            }

            let wordIndexes = entry.wordStart...entry.wordEnd
            guard !wordIndexes.contains(where: claimedWordIndexes.contains) else { continue }
            let range = wordRanges[entry.wordStart].lowerBound..<wordRanges[entry.wordEnd].upperBound
            guard let linkRange = linkableRange(within: range, in: text),
                !isInsideMisakiLinkDisplay(linkRange, in: text)
            else {
                continue
            }

            let originalText = String(text[range])
            guard canonical(originalText) == canonical(entry.word) else { continue }

            claimedWordIndexes.formUnion(wordIndexes)
            replacements.append(
                (
                    range: NSRange(linkRange, in: text),
                    displayText: String(text[linkRange]),
                    ipa: entry.ipa
                ))
        }

        guard !replacements.isEmpty else { return text }

        var result = text
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[\(replacement.displayText)](/\(replacement.ipa)/)")
        }
        return result
    }

    private func sortSpecificEntriesFirst(
        _ lhs: PronunciationOccurrenceOverride,
        _ rhs: PronunciationOccurrenceOverride
    ) -> Bool {
        if lhs.wordStart != rhs.wordStart { return lhs.wordStart < rhs.wordStart }
        return lhs.wordEnd > rhs.wordEnd
    }

    private func canonical(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func linkableRange(
        within range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound

        while lower < upper, !text[lower].isLetter, !text[lower].isNumber {
            lower = text.index(after: lower)
        }

        while lower < upper {
            let previous = text.index(before: upper)
            if text[previous].isLetter || text[previous].isNumber { break }
            upper = previous
        }

        guard lower < upper else { return nil }
        return lower..<upper
    }

    private func isInsideMisakiLinkDisplay(_ range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == "]" { return false }
            if text[index] == "[" { return true }
        }
        return false
    }
}
