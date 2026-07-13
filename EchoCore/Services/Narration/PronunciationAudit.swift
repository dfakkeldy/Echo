// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Portable evidence for one pronunciation choice made before synthesis.
nonisolated struct PronunciationAuditDecision: Codable, Equatable, Sendable {
    enum Source: String, Codable, Equatable, Sendable {
        case occurrenceOverride
        case bookOverride
        case globalOverride
        case builtInOverride
        case contextualHomograph
        case monitoredLexicon
        case fallback
    }

    enum TimingPrecision: String, Codable, Equatable, Sendable {
        case exactSynthesisWord
        case blockAnchorFallback
    }

    struct AudioRange: Codable, Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
    }

    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let normalizedWord: String
    let sourceWord: String
    let sourceContext: String
    let selectedIPA: String
    /// IDs for `selectedIPA` only. Kokoro's synthetic BOS/EOS tokens are excluded.
    let kokoroTokenIDs: [Int32]
    let source: Source
    let ruleID: String
    let rationale: String
    let chapterIndex: Int?
    let chapterRelativeAudioRange: AudioRange?
    let bookRelativeAudioRange: AudioRange?
    let timingPrecision: TimingPrecision?

    init(
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String,
        sourceWord: String,
        sourceContext: String,
        selectedIPA: String,
        kokoroTokenIDs: [Int32],
        source: Source,
        ruleID: String,
        rationale: String,
        chapterIndex: Int? = nil,
        chapterRelativeAudioRange: AudioRange? = nil,
        bookRelativeAudioRange: AudioRange? = nil,
        timingPrecision: TimingPrecision? = nil
    ) {
        self.blockID = blockID
        self.wordStart = wordStart
        self.wordEnd = wordEnd
        self.normalizedWord = normalizedWord
        self.sourceWord = sourceWord
        self.sourceContext = sourceContext
        self.selectedIPA = selectedIPA
        self.kokoroTokenIDs = kokoroTokenIDs
        self.source = source
        self.ruleID = ruleID
        self.rationale = rationale
        self.chapterIndex = chapterIndex
        self.chapterRelativeAudioRange = chapterRelativeAudioRange
        self.bookRelativeAudioRange = bookRelativeAudioRange
        self.timingPrecision = timingPrecision
    }
}

/// Rewrite-stage evidence. The render planner adds Kokoro IDs through its existing
/// vocabulary owner before exposing a portable `PronunciationAuditDecision`.
nonisolated struct PronunciationDecisionSeed: Equatable, Sendable {
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let normalizedWord: String
    let sourceWord: String
    let sourceContext: String
    let selectedIPA: String
    let source: PronunciationAuditDecision.Source
    let ruleID: String
    let rationale: String

    func materialized(kokoroTokenIDs: [Int32]) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: sourceWord,
            sourceContext: sourceContext,
            selectedIPA: selectedIPA,
            kokoroTokenIDs: kokoroTokenIDs,
            source: source,
            ruleID: ruleID,
            rationale: rationale)
    }
}

nonisolated struct PronunciationRewriteResult: Equatable, Sendable {
    let text: String
    let decisionSeeds: [PronunciationDecisionSeed]
}

/// Shared source-mapping rules for occurrence, dictionary, and regex rewriters.
nonisolated enum PronunciationAuditContext {
    private static let contextRadius = 5

    static func normalizedWord(_ sourceWord: String) -> String {
        let display = MisakiPronunciationMarkup.displayText(from: sourceWord)
        return WordTokenizer.words(in: display)
            .map { word in
                String(word)
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func ruleComponent(_ sourceWord: String) -> String {
        let normalized = normalizedWord(sourceWord)
        var result = ""
        var needsSeparator = false
        for character in normalized {
            if character.isLetter || character.isNumber {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.append(contentsOf: character.lowercased())
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        return result
    }

    static func sourceContext(
        in sourceText: String,
        wordStart: Int,
        wordEnd: Int
    ) -> String {
        let displayText = MisakiPronunciationMarkup.displayText(from: sourceText)
        let words = WordTokenizer.words(in: displayText)
        guard !words.isEmpty,
            wordStart >= 0,
            wordEnd >= wordStart,
            wordStart < words.count
        else {
            return ""
        }

        let boundedEnd = min(wordEnd, words.count - 1)
        let lower = max(0, wordStart - contextRadius)
        let upper = min(words.count - 1, boundedEnd + contextRadius)
        return words[lower...upper].map(String.init).joined(separator: " ")
    }

    /// Maps a source regex range onto the canonical whitespace-token span of the
    /// markup-free display text. This deliberately does not use a resolver loop index.
    static func wordSpan(
        containing sourceRange: Range<String.Index>,
        in sourceText: String
    ) -> ClosedRange<Int>? {
        let displayText = MisakiPronunciationMarkup.displayText(from: sourceText)
        let displayPrefix = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.lowerBound]))
        let displayThroughMatch = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.upperBound]))
        let matchRange = NSRange(
            location: displayPrefix.utf16.count,
            length: displayThroughMatch.utf16.count - displayPrefix.utf16.count)
        guard matchRange.length > 0 else { return nil }

        let matchingIndexes = WordTokenizer.wordRanges(in: displayText).enumerated().compactMap {
            index, wordRange in
            let range = NSRange(wordRange, in: displayText)
            return NSIntersectionRange(range, matchRange).length > 0 ? index : nil
        }
        guard let first = matchingIndexes.first, let last = matchingIndexes.last else {
            return nil
        }
        return first...last
    }
}
