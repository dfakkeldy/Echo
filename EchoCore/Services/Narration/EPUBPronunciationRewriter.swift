// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum EPUBPronunciationRewriter {
    static func rewrite(_ input: String, block: EPubBlockRecord) throws
        -> PronunciationRewriteResult
    {
        let spans = try EPUBPronunciationStorage.decode(block.pronunciationAnnotations)
        guard !spans.isEmpty else { return .init(text: input, decisionSeeds: []) }
        let display = MisakiPronunciationMarkup.displayText(from: input)
        let vocab = try KokoroPhonemeVocab()
        // Map original display offsets into the string containing user links.
        // An overlapping user correction suppresses the entire EPUB span.
        var boundaries: [Int: String.Index] = [:]
        var userSpans: [Range<Int>] = []
        var cursor = input.startIndex
        var offset = 0
        while cursor < input.endIndex {
            boundaries[offset] = cursor
            if let link = MisakiPronunciationMarkup.link(in: input, startingAt: cursor) {
                userSpans.append(offset..<(offset + link.displayText.count))
                offset += link.displayText.count
                cursor = link.range.upperBound
            } else {
                offset += 1
                cursor = input.index(after: cursor)
            }
        }
        boundaries[offset] = input.endIndex
        var result = input
        var seeds: [PronunciationDecisionSeed] = []
        var previousEnd = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= previousEnd, span.end > span.start, span.end <= display.count,
                String(display.dropFirst(span.start).prefix(span.end - span.start)) == span.text,
                !span.text.contains(where: { "[]()/".contains($0) }), !span.ipa.isEmpty,
                !span.ipa.contains(KokoroPhonemeVocab.oovMarker), span.ipa.count <= 300
            else {
                throw EPUBPronunciationError(
                    detail:
                        "Annotation no longer matches its original text in block \(block.blockIndex). Reimport the EPUB."
                )
            }
            _ = try vocab.validatedIDs(forPhonemes: span.ipa)
            previousEnd = span.end
        }
        for span in spans.sorted(by: { $0.start > $1.start }) {
            let displayRange = span.start..<span.end
            if userSpans.contains(where: { $0.overlaps(displayRange) }) { continue }
            guard let lower = boundaries[span.start], let upper = boundaries[span.end],
                let words = PronunciationAuditContext.wordSpan(
                    overlappingDisplayCharacterRange: displayRange, in: display)
            else {
                throw EPUBPronunciationError(
                    detail: "Cannot address annotation in block \(block.blockIndex).")
            }
            // Convert indices to offsets before mutating; replacements proceed right-to-left.
            let range =
                input.distance(
                    from: input.startIndex, to: lower)..<input.distance(
                    from: input.startIndex, to: upper)
            let resultLower = result.index(result.startIndex, offsetBy: range.lowerBound)
            let resultUpper = result.index(result.startIndex, offsetBy: range.upperBound)
            let ipa = synthesisIPA(span.ipa)
            result.replaceSubrange(resultLower..<resultUpper, with: "[\(span.text)](/\(ipa)/)")
            seeds.append(
                .init(
                    blockID: block.id, wordStart: words.lowerBound, wordEnd: words.upperBound,
                    normalizedWord: PronunciationAuditContext.normalizedWord(span.text),
                    sourceWord: span.text,
                    sourceContext: PronunciationAuditContext.sourceContext(
                        in: display, wordStart: words.lowerBound, wordEnd: words.upperBound),
                    selectedIPA: ipa,
                    source: span.source == .inline ? .epubInline : .epubLexicon,
                    ruleID: "epub.\(span.source.rawValue).ipa-v1",
                    rationale: "Explicit EPUB pronunciation instruction."))
        }
        return .init(text: result, decisionSeeds: Array(seeds.reversed()))
    }

    /// Standard IPA marks a stressed syllable before its onset, but Kokoro was
    /// trained on Misaki's stress immediately before the vowel. Sending ˈɡɪt
    /// unchanged can synthesize an extra vowel before ɡ. Adapt at render time so
    /// existing persisted annotations receive the same conversion as new books.
    static func synthesisIPA(_ ipa: String) -> String {
        let vowels = Set("aeiouæɑɒɔəɚɛɜɪʊʌAIWOY")
        let consonants = Set("bdfhjklmnprstvwzɡŋθðɹʃʒʧʤT")
        let characters = Array(ipa)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "ˈ" || character == "ˌ" {
                var vowelIndex = index + 1
                while vowelIndex < characters.count, consonants.contains(characters[vowelIndex]) {
                    vowelIndex += 1
                }
                if vowelIndex < characters.count, vowels.contains(characters[vowelIndex]) {
                    result.append(contentsOf: characters[(index + 1)..<vowelIndex])
                    result.append(character)
                    index = vowelIndex
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }
}
