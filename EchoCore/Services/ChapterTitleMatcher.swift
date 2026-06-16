// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Matches audiobook chapter titles (from M4B metadata) to EPUB heading blocks
/// using fuzzy string comparison.
///
/// This serves as **Tier 0** in the alignment pipeline — a zero-cost bootstrap
/// that creates anchors from metadata before any audio transcription runs.
///
/// Many M4B/M4A files embed chapter titles (e.g., "Chapter 1: The Beginning")
/// that directly correspond to `<h1>`–`<h6>` elements in the EPUB. Matching
/// these gives us high-confidence anchors at essentially zero cost, shrinking
/// the search space for the downstream DTW pipeline.
struct ChapterTitleMatcher {

    /// A single title-to-heading match.
    struct Match: Equatable {
        let chapter: Chapter
        let block: EPubBlockRecord
        /// Composite similarity score in [0.0, 1.0].
        let confidence: Double
    }

    /// Confidence thresholds for match quality tiers.
    enum Threshold {
        /// Automatic anchor — skip DTW transcription for this chapter entirely.
        static let highConfidence: Double = 0.85
        /// Create anchor but still run DTW for refinement.
        static let mediumConfidence: Double = 0.60
    }

    // MARK: - Public API

    /// Finds the best-matching EPUB heading for each audiobook chapter title.
    ///
    /// - Parameters:
    ///   - chapters: Audiobook chapters parsed from M4B metadata via
    ///     `ChapterService.parseChapters(from:)`. Only chapters with non-nil,
    ///     non-empty, non-generic titles are considered — see
    ///     `isGenericNumericTitle(_:)`.
    ///   - blocks: All EPUB blocks in reading order. Only blocks with
    ///     `blockKind == "heading"` and non-nil `text` are candidates.
    /// - Returns: Matches where confidence ≥ `Threshold.mediumConfidence`,
    ///   sorted by chapter index. Each chapter appears at most once (its best
    ///   heading match), and each heading block appears at most once (its
    ///   strongest chapter) — anchoring two audio times to one block would
    ///   make the alignment timeline non-monotonic.
    static func matchChapterTitles(
        chapters: [Chapter],
        blocks: [EPubBlockRecord]
    ) -> [Match] {
        let headingBlocks = blocks.filter {
            $0.blockKind == EPubBlockRecord.Kind.heading.rawValue && $0.text != nil
        }
        guard !headingBlocks.isEmpty else { return [] }

        var matches: [Match] = []

        for chapter in chapters {
            guard let title = chapter.title?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else {
                continue
            }

            // Generic track labels ("Chapter 7", "Track 03", "12") number
            // tracks, not book chapters — track 1 is routinely opening
            // credits, shifting every label off the EPUB's numbering. They
            // carry no correspondence signal, so leave those chapters to the
            // content-based DTW pipeline.
            guard !isGenericNumericTitle(title) else { continue }

            var best: (block: EPubBlockRecord, confidence: Double)?

            for heading in headingBlocks {
                guard let headingText = heading.text else { continue }
                let confidence = similarity(between: title, and: headingText)
                if confidence > (best?.confidence ?? 0) {
                    best = (heading, confidence)
                }
            }

            if let best, best.confidence >= Threshold.mediumConfidence {
                matches.append(Match(
                    chapter: chapter,
                    block: best.block,
                    confidence: best.confidence
                ))
            }
        }

        // One block, one chapter: when several chapters claim the same
        // heading, keep the strongest claim (earliest chapter wins ties).
        var bestByBlockID: [String: Match] = [:]
        for match in matches {
            if let existing = bestByBlockID[match.block.id],
               existing.confidence >= match.confidence {
                continue
            }
            bestByBlockID[match.block.id] = match
        }

        return bestByBlockID.values.sorted { $0.chapter.index < $1.chapter.index }
    }

    // MARK: - Generic Title Detection

    /// True when a title is a generic track label — a bare number, or a
    /// structural keyword plus a number ("Chapter 7", "Pt. 2", "Track 03",
    /// "Chapter IX", "12").
    ///
    /// M4B chapter metadata frequently numbers *tracks* rather than book
    /// chapters (Audible rips label opening credits "Chapter 1"), so an exact
    /// title match proves nothing about which EPUB heading the audio
    /// corresponds to. Tier 0 must skip these titles entirely rather than
    /// create anchors from them.
    static func isGenericNumericTitle(_ title: String) -> Bool {
        let normalized = normalize(title)
        guard !normalized.isEmpty else { return false }

        // Structural keyword followed by an arabic or roman number.
        if normalized.range(of: Self.keywordNumberPattern,
                            options: .regularExpression) != nil {
            return true
        }
        // A bare number, optionally decorated with separators ("12", "07.").
        return normalized.range(of: #"^[\s.:#\-–—]*[0-9]+[\s.:#\-–—]*$"#,
                                options: .regularExpression) != nil
    }

    private static let keywordNumberPattern =
        #"^(chapter|chap|ch|part|pt|track|section|sec|disc|book)[\s.:#\-–—]*([0-9]+|[ivxlcdm]+)[\s.:#\-–—]*$"#

    // MARK: - Similarity

    /// Computes a composite similarity score between two title strings.
    ///
    /// Combines character-level Levenshtein distance and token-level Jaccard
    /// overlap, returning the **maximum** of the two — so a match succeeds if
    /// either the full-string edit distance or the bag-of-words overlap is
    /// strong.
    ///
    /// Numbers override both metrics: "Chapter 2" and "Chapter 1" are
    /// *different places* no matter how similar the surrounding words are,
    /// so when both titles carry numbers and neither side's numbers contain
    /// the other's, the match is disqualified outright.
    ///
    /// - Returns: A value in [0.0, 1.0] where 1.0 is an exact match.
    static func similarity(between a: String, and b: String) -> Double {
        let normalizedA = normalize(a)
        let normalizedB = normalize(b)

        let numbersA = numberTokens(in: normalizedA)
        let numbersB = numberTokens(in: normalizedB)
        if !numbersA.isEmpty, !numbersB.isEmpty,
           !numbersA.isSubset(of: numbersB), !numbersB.isSubset(of: numbersA) {
            return 0.0
        }

        // Character-level Levenshtein on the full normalized strings.
        let stringConfidence = normalizedA.normalizedLevenshteinSimilarity(to: normalizedB)

        // Short-circuit on near-perfect match — avoids tokenization overhead.
        if stringConfidence >= 0.95 { return stringConfidence }

        // Token-level Jaccard for cases like "Ch 1: The Beginning" vs
        // "Chapter One — The Beginning" where character edit distance is
        // high but the meaningful word overlap is strong.
        let tokensA = tokenize(normalizedA)
        let tokensB = tokenize(normalizedB)

        guard !tokensA.isEmpty, !tokensB.isEmpty else {
            return stringConfidence
        }

        let setA = Set(tokensA)
        let setB = Set(tokensB)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        let wordConfidence = union > 0 ? Double(intersection) / Double(union) : 0.0

        return max(stringConfidence, wordConfidence)
    }

    // MARK: - Private Helpers

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    /// Lowercase, collapse whitespace, trim.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Split into tokens for Jaccard comparison: words of 2+ characters,
    /// plus standalone numbers of any length — digits are what distinguish
    /// "Chapter 1" from "Chapter 2", so they must survive tokenization.
    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: nonAlphanumerics)
            .filter { $0.count >= 2 || $0.contains(where: { $0.isASCII && $0.isNumber }) }
    }

    /// Maximal ASCII digit runs in a normalized string, with leading zeros
    /// stripped so "03" and "3" compare equal ("chapter 12: 1944" → {"12",
    /// "1944"}).
    private static func numberTokens(in normalized: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let stripped = current.drop(while: { $0 == "0" })
            tokens.insert(stripped.isEmpty ? "0" : String(stripped))
            current = ""
        }
        for character in normalized {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
