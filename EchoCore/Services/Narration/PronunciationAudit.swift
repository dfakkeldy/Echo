// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Immutable token-level evidence copied from Misaki's final mutable token list.
/// Character offsets are half-open and address the chunk's markup-free display text.
nonisolated struct PronunciationTokenEvidence: Codable, Equatable, Sendable {
    let text: String
    let selectedPhonemes: String
    let lexicalTag: String?
    let rating: Int?
    let displayCharacterRange: Range<Int>
    let usedFallback: Bool
}

/// Whether Misaki's final token surface safely addresses the chunk display text.
/// A mismatch preserves synthesis and aggregate fallback context, but invalidates
/// every token range because those ranges no longer address authored text.
nonisolated enum PronunciationEvidenceValidation: Codable, Equatable, Sendable {
    case matched
    case mismatch(
        expectedDisplayText: String,
        reconstructedSpokenSurface: String)
}

/// Range-free evidence that a planned chunk could not produce safe token ranges.
/// This is intentionally portable so a later manifest layer can report an
/// incomplete pronunciation audit without fabricating a source-word span.
nonisolated struct PronunciationAuditDiagnostic: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Equatable, Sendable {
        case spokenSurfaceMismatch
        case incompleteRender
        case qualityRejected
    }

    let reason: Reason
    let blockID: String
    let chunkIndex: Int
    let chapterIndex: Int?
    let expectedDisplayText: String
    let reconstructedSpokenSurface: String
    let fallbackHits: [PronunciationFallbackHit]

    init(
        reason: Reason,
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int? = nil,
        expectedDisplayText: String,
        reconstructedSpokenSurface: String,
        fallbackHits: [PronunciationFallbackHit]
    ) {
        self.reason = reason
        self.blockID = blockID
        self.chunkIndex = chunkIndex
        self.chapterIndex = chapterIndex
        self.expectedDisplayText = expectedDisplayText
        self.reconstructedSpokenSurface = reconstructedSpokenSurface
        self.fallbackHits = fallbackHits
    }

    func attachingChapter(_ chapterIndex: Int) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: reason,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: reconstructedSpokenSurface,
            fallbackHits: fallbackHits)
    }

    static func incompleteRender(
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int,
        expectedDisplayText: String,
        fallbackHits: [PronunciationFallbackHit]
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .incompleteRender,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: "",
            fallbackHits: fallbackHits)
    }

    static func qualityRejected(
        blockID: String,
        chunkIndex: Int,
        chapterIndex: Int,
        expectedDisplayText: String,
        fallbackHits: [PronunciationFallbackHit]
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .qualityRejected,
            blockID: blockID,
            chunkIndex: chunkIndex,
            chapterIndex: chapterIndex,
            expectedDisplayText: expectedDisplayText,
            reconstructedSpokenSurface: "",
            fallbackHits: fallbackHits)
    }
}

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

    func attachingRenderTiming(
        chapterIndex: Int,
        chapterRelativeAudioRange: AudioRange?,
        timingPrecision: TimingPrecision?
    ) -> PronunciationAuditDecision {
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
            rationale: rationale,
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: chapterRelativeAudioRange,
            bookRelativeAudioRange: bookRelativeAudioRange,
            timingPrecision: timingPrecision)
    }

    /// Preserves the chapter-relative receipt while projecting it into the
    /// completed audiobook's timebase. The capture filename's chapter index is
    /// canonical during resume assembly, so it replaces any stale embedded index.
    func attachingBookTiming(
        chapterIndex: Int,
        chapterOffset: TimeInterval
    ) -> PronunciationAuditDecision {
        let bookRelativeAudioRange = chapterRelativeAudioRange.map {
            AudioRange(
                start: chapterOffset + $0.start,
                end: chapterOffset + $0.end)
        }
        return PronunciationAuditDecision(
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
            rationale: rationale,
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: chapterRelativeAudioRange,
            bookRelativeAudioRange: bookRelativeAudioRange,
            timingPrecision: timingPrecision)
    }
}

/// Whether every completed chapter capture contains the exact render receipt.
/// Legacy captures remain usable for audio/sidecar resume, but cannot prove
/// pronunciation coverage retroactively.
nonisolated enum PronunciationAuditCoverage: String, Codable, Equatable, Sendable {
    case complete
    case incompleteLegacyCapture
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

/// One deterministic declaration for every pronunciation Echo actively watches.
/// Built-in keys remain owned by `PronunciationOverrides`; the contextual list
/// mirrors every target handled by `HomographPronunciationResolver`; ordinary
/// lexicon regressions are added explicitly here.
nonisolated enum PronunciationWatchVocabulary {
    private static let contextualHomographWords: Set<String> = [
        "arithmetic",
        "content",
        "live",
        "lives",
        "read",
        "record",
        "resume",
        "resumes",
        "résumé",
        "résumés",
    ]
    private static let monitoredOrdinaryLexiconWords: Set<String> = ["verified"]

    @MainActor static let words: Set<String> = {
        let builtIns = PronunciationOverrides.builtInDefaults.keys.map {
            PronunciationAuditContext.normalizedWord($0)
        }
        return Set(builtIns)
            .union(contextualHomographWords)
            .union(monitoredOrdinaryLexiconWords)
    }()
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

    /// Maps a validated token range in chunk display characters onto that chunk's
    /// canonical whitespace-token span. Misaki's own token indices are deliberately
    /// excluded because they address its preprocessed string, not authored markup.
    static func wordSpan(
        overlappingDisplayCharacterRange characterRange: Range<Int>,
        in displayText: String
    ) -> ClosedRange<Int>? {
        guard
            characterRange.lowerBound >= 0,
            characterRange.lowerBound < characterRange.upperBound,
            characterRange.upperBound <= displayText.count
        else {
            return nil
        }

        let lowerBound = displayText.index(
            displayText.startIndex,
            offsetBy: characterRange.lowerBound)
        let upperBound = displayText.index(
            displayText.startIndex,
            offsetBy: characterRange.upperBound)
        let tokenRange = lowerBound..<upperBound
        let matchingIndexes = WordTokenizer.wordRanges(in: displayText).enumerated().compactMap {
            index, wordRange in
            wordRange.overlaps(tokenRange) ? index : nil
        }
        guard let first = matchingIndexes.first, let last = matchingIndexes.last else {
            return nil
        }
        return first...last
    }

    @MainActor static func decisionSeed(
        for evidence: PronunciationTokenEvidence,
        blockID: String,
        chunkDisplayText: String,
        blockDisplayText: String,
        wordBase: Int
    ) -> PronunciationDecisionSeed? {
        guard !evidence.selectedPhonemes.isEmpty else { return nil }
        let normalizedWord = normalizedWord(evidence.text)
        guard
            !normalizedWord.isEmpty,
            evidence.usedFallback || PronunciationWatchVocabulary.words.contains(normalizedWord),
            let localWordSpan = wordSpan(
                overlappingDisplayCharacterRange: evidence.displayCharacterRange,
                in: chunkDisplayText)
        else {
            return nil
        }

        let wordStart = wordBase + localWordSpan.lowerBound
        let wordEnd = wordBase + localWordSpan.upperBound
        let source: PronunciationAuditDecision.Source =
            evidence.usedFallback ? .fallback : .monitoredLexicon
        let ruleKind = evidence.usedFallback ? "fallback" : "lexicon"
        let rationale =
            evidence.usedFallback
            ? "Deterministic G2P fallback selected for “\(evidence.text)”."
            : "Watched ordinary-lexicon pronunciation selected for “\(evidence.text)”."
        return PronunciationDecisionSeed(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord,
            sourceWord: evidence.text,
            sourceContext: sourceContext(
                in: blockDisplayText,
                wordStart: wordStart,
                wordEnd: wordEnd),
            selectedIPA: evidence.selectedPhonemes,
            source: source,
            ruleID: "g2p.\(ruleKind).\(ruleComponent(evidence.text))",
            rationale: rationale)
    }
}
