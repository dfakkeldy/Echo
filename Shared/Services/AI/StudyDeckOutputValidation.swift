// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Public API

/// Returns `true` if `text` contains at least one valid Anki-style cloze deletion.
///
/// A valid cloze deletion is `{{cN::content}}` where N > 0, content is non-empty,
/// and at least one marker has ordinal == 1 (`c1`). A stray `}}` or any malformed
/// marker causes the entire string to be rejected.
///
/// Ported verbatim from EchoDeckBuilder `AIModelOutputValidator` (private extension
/// `String.hasValidClozeMarkers`).
nonisolated func studyDeckHasValidClozeMarkers(_ text: String) -> Bool {
    text.hasValidClozeMarkers
}

/// Returns `true` if any of `candidateTexts` contains a verbatim 14-word window
/// from `sourceText` that is ≥ 80 characters — indicating a long source quotation.
///
/// Ported verbatim from EchoDeckBuilder `AIModelOutputValidator.rejectLongSourceQuotation`,
/// converted from throwing to returning a `Bool` (`true` = would have thrown).
nonisolated func studyDeckIsLongSourceQuotation(
    _ candidateTexts: [String],
    sourceText: String
) -> Bool {
    let sourceWords = sourceText.normalizedQuoteWords
    guard sourceWords.count >= 14 else { return false }

    let normalizedCandidates = candidateTexts.map(\.normalizedForQuoteDetection)
    for startIndex in 0...(sourceWords.count - 14) {
        let phrase = sourceWords[startIndex..<(startIndex + 14)].joined(separator: " ")
        guard phrase.count >= 80 else { continue }
        if normalizedCandidates.contains(where: { $0.contains(phrase) }) {
            return true
        }
    }
    return false
}

// MARK: - Private String helpers (ported from EDB)

extension String {
    /// Lowercases and splits on non-alphanumeric, rejoining with single spaces.
    fileprivate nonisolated var normalizedForQuoteDetection: String {
        lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// The normalized word list used for the sliding-window comparison.
    fileprivate nonisolated var normalizedQuoteWords: [String] {
        normalizedForQuoteDetection
            .split(separator: " ")
            .map(String.init)
    }

    /// `true` only if the string contains ≥ 1 well-formed `{{cN::content}}` deletion
    /// **and** at least one marker has ordinal == 1.
    fileprivate nonisolated var hasValidClozeMarkers: Bool {
        var foundC1 = false
        var cursor = startIndex

        while cursor < endIndex {
            // Stray closing brace → immediately invalid
            if hasPrefix("}}", at: cursor) {
                return false
            }
            guard hasPrefix("{{", at: cursor) else {
                cursor = index(after: cursor)
                continue
            }

            // Advance past "{{"
            var markerCursor = index(cursor, offsetBy: 2)
            guard markerCursor < endIndex, self[markerCursor] == "c" else {
                return false
            }
            markerCursor = index(after: markerCursor)

            // Parse ordinal digits
            let ordinalStart = markerCursor
            while markerCursor < endIndex, self[markerCursor].isNumber {
                markerCursor = index(after: markerCursor)
            }
            guard ordinalStart < markerCursor,
                let ordinal = Int(self[ordinalStart..<markerCursor]),
                ordinal > 0,
                hasPrefix("::", at: markerCursor)
            else {
                return false
            }

            // Advance past "::"
            let contentStart = index(markerCursor, offsetBy: 2)
            guard let closeRange = range(of: "}}", range: contentStart..<endIndex) else {
                return false
            }

            // Content must not itself contain marker delimiters
            let contentAndHint = self[contentStart..<closeRange.lowerBound]
            guard !contentAndHint.contains("{{"),
                !contentAndHint.contains("}}")
            else {
                return false
            }

            // The part before an optional hint separator must be non-empty
            let content =
                contentAndHint
                .split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }

            if ordinal == 1 { foundC1 = true }
            cursor = closeRange.upperBound
        }

        return foundC1
    }

    /// Returns `true` if `prefix` appears at exactly `index` in this string.
    fileprivate nonisolated func hasPrefix(_ prefix: String, at index: Index) -> Bool {
        range(of: prefix, range: index..<endIndex)?.lowerBound == index
    }
}
