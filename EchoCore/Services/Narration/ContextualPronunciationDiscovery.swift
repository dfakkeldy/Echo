// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import NaturalLanguage

/// Finds known contextual ambiguities without changing narration text. The
/// returned sentence window is local evidence for Phase 2 shadow evaluation.
nonisolated enum ContextualPronunciationDiscovery {
    private struct SourceToken {
        let text: String
        let normalized: String
        let range: Range<String.Index>
        let isAuthoredLinkDisplay: Bool
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[\p{L}]+\b"#)

    static func discover(
        text: String,
        blockID: String,
        isHidden: Bool = false,
        isCodeBlock: Bool = false
    ) -> [ContextualPronunciationOccurrence] {
        guard !isHidden, !isCodeBlock, !text.isEmpty else { return [] }

        let sourceTokens = tokens(in: text)
        let familyTokenIndexes = sourceTokens.indices.filter {
            ContextualPronunciationFamilies.family(for: sourceTokens[$0].normalized) != nil
        }
        guard !familyTokenIndexes.isEmpty else { return [] }

        let familyRanges = familyTokenIndexes.map { sourceTokens[$0].range }
        let properNameRisks = UniversalPronunciationResolver.properNameRiskFlags(
            in: text,
            candidateRanges: familyRanges)
        let displayText = MisakiPronunciationMarkup.displayText(from: text)
        let displayWords = WordTokenizer.words(in: displayText)
        let sentenceRanges = sentences(in: displayText)

        var occurrences: [ContextualPronunciationOccurrence] = []
        occurrences.reserveCapacity(familyTokenIndexes.count)
        for (familyOffset, tokenIndex) in familyTokenIndexes.enumerated() {
            let token = sourceTokens[tokenIndex]
            guard !token.isAuthoredLinkDisplay,
                !properNameRisks[familyOffset],
                let family = ContextualPronunciationFamilies.family(for: token.normalized),
                let wordSpan = PronunciationAuditContext.wordSpan(
                    containing: token.range,
                    in: text),
                wordSpan.lowerBound == wordSpan.upperBound,
                displayWords.indices.contains(wordSpan.lowerBound),
                PronunciationAuditContext.normalizedWord(
                    String(displayWords[wordSpan.lowerBound])) == token.normalized,
                let sentenceIndex = sentenceIndex(
                    containing: token.range,
                    sourceText: text,
                    displayText: displayText,
                    sentenceRanges: sentenceRanges)
            else {
                continue
            }

            let analysis = HomographPronunciationResolver.contextualAnalysis(
                in: text,
                wordStart: wordSpan.lowerBound)
            occurrences.append(
                ContextualPronunciationOccurrence(
                    occurrenceID: occurrenceID(
                        blockID: blockID,
                        wordStart: wordSpan.lowerBound,
                        wordEnd: wordSpan.upperBound,
                        normalizedWord: token.normalized),
                    blockID: blockID,
                    wordStart: wordSpan.lowerBound,
                    wordEnd: wordSpan.upperBound,
                    targetWord: token.text,
                    precedingSentence: sentence(
                        before: sentenceIndex,
                        in: sentenceRanges,
                        displayText: displayText),
                    targetSentence: sentenceText(
                        sentenceRanges[sentenceIndex],
                        in: displayText),
                    followingSentence: sentence(
                        after: sentenceIndex,
                        in: sentenceRanges,
                        displayText: displayText),
                    familyID: family.familyID,
                    candidates: family.candidates,
                    deterministicCandidateID: analysis.candidateID,
                    deterministicRuleID: analysis.ruleID,
                    deterministicStrength: analysis.strength))
        }
        return occurrences
    }

    private static func tokens(in text: String) -> [SourceToken] {
        var result: [SourceToken] = []
        var plainTextStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) else {
                index = text.index(after: index)
                continue
            }
            appendTokens(
                in: plainTextStart..<link.range.lowerBound,
                of: text,
                isAuthoredLinkDisplay: false,
                to: &result)
            appendTokens(
                in: link.displayText.startIndex..<link.displayText.endIndex,
                of: text,
                isAuthoredLinkDisplay: true,
                to: &result)
            index = link.range.upperBound
            plainTextStart = index
        }

        appendTokens(
            in: plainTextStart..<text.endIndex,
            of: text,
            isAuthoredLinkDisplay: false,
            to: &result)
        return result
    }

    private static func appendTokens(
        in searchRange: Range<String.Index>,
        of text: String,
        isAuthoredLinkDisplay: Bool,
        to tokens: inout [SourceToken]
    ) {
        let nsSearchRange = NSRange(searchRange, in: text)
        tokens.append(
            contentsOf: wordRegex.matches(in: text, range: nsSearchRange).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let value = String(text[range])
                return SourceToken(
                    text: value,
                    normalized: PronunciationAuditContext.canonicalEnglishKeySpelling(value),
                    range: range,
                    isAuthoredLinkDisplay: isAuthoredLinkDisplay)
            })
    }

    private static func sentences(in displayText: String) -> [Range<String.Index>] {
        guard !displayText.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = displayText
        var result: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: displayText.startIndex..<displayText.endIndex) {
            range, _ in
            result.append(range)
            return true
        }
        return result
    }

    private static func sentenceIndex(
        containing sourceRange: Range<String.Index>,
        sourceText: String,
        displayText: String,
        sentenceRanges: [Range<String.Index>]
    ) -> Int? {
        let displayPrefix = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.lowerBound]))
        let displayThroughTarget = MisakiPronunciationMarkup.displayText(
            from: String(sourceText[..<sourceRange.upperBound]))
        let targetRange = NSRange(
            location: displayPrefix.utf16.count,
            length: displayThroughTarget.utf16.count - displayPrefix.utf16.count)
        guard targetRange.length > 0 else { return nil }

        return sentenceRanges.firstIndex {
            NSIntersectionRange(NSRange($0, in: displayText), targetRange).length > 0
        }
    }

    private static func sentence(
        before index: Int,
        in ranges: [Range<String.Index>],
        displayText: String
    ) -> String? {
        guard index > ranges.startIndex else { return nil }
        return sentenceText(ranges[index - 1], in: displayText)
    }

    private static func sentence(
        after index: Int,
        in ranges: [Range<String.Index>],
        displayText: String
    ) -> String? {
        let following = index + 1
        guard following < ranges.endIndex else { return nil }
        return sentenceText(ranges[following], in: displayText)
    }

    private static func sentenceText(
        _ range: Range<String.Index>,
        in displayText: String
    ) -> String {
        String(displayText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func occurrenceID(
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String
    ) -> String {
        let payload = [
            ContextualPronunciationFamilies.promptSchemaVersion,
            blockID,
            String(wordStart),
            String(wordEnd),
            normalizedWord,
        ].joined(separator: "\0")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
