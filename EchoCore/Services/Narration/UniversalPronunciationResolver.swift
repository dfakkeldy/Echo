// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Deterministic, context-free pronunciation enrichment applied after authored
/// overrides and before contextual homograph handling.
nonisolated enum UniversalPronunciationResolver {
    static let morphologyVersion = "morphology-v1"
    static let morphologyIdentitySchemaVersion = 1
    static let suffixIPA = "əbəl"
    static let minimumBaseLength = 3
    static let properNamePolicyVersion = "proper-name-risk-v5"
    static let baseEvidencePolicyVersion = "kokoro-nonfallback-rating3-v1"
    /// Common honorific, military, professional, organizational, geographic,
    /// reference, and calendar abbreviations. A period after one of these is
    /// not sufficient evidence that the following capitalized token begins a
    /// new sentence.
    static let ambiguousPeriodAbbreviations: Set<String> = [
        "adm", "adv", "apr", "approx", "art", "assoc", "asst", "atty", "aug", "ave",
        "blvd", "br", "brig", "bros", "capt", "ch", "cmdr", "co", "col",
        "calif", "corp", "cpl", "ctr", "dec", "dept", "det", "dist", "dr", "ens", "eq",
        "esq",
        "est", "etc", "exec", "feb", "fig", "fr", "fri", "gen", "gov", "hon", "hwy",
        "inc", "insp", "jan", "jr", "jul", "jun", "jct", "ln", "lt", "ltd",
        "m.d", "maj", "mar", "messrs", "mlle", "mon", "mr", "mrs", "ms", "msgr",
        "mt", "mx", "no", "nov", "oct", "ofc", "pfc", "ph.d", "pkwy", "pl", "pp",
        "pres", "prof", "pvt", "rd", "rep", "rev", "rte", "sat", "sec", "sen", "sep",
        "sept", "sgt", "sq", "sr", "st", "ste", "sun", "supt", "terr", "thu", "tue",
        "univ", "vol", "vs", "wed",
    ]
    static let contextualExclusions: Set<String> = [
        "content", "read", "live", "lives", "record", "records",
    ]
    static let exceptionWords: Set<String> = [
        "comfortable", "content", "livable", "live", "lives", "read",
        "readable", "record", "recordable", "records", "responsible",
    ]

    private enum DerivationRule: String, CaseIterable {
        case ableExactBase = "morphology.able.exact-base.v1"
        case ableSilentE = "morphology.able.silent-e.v1"
        case ibleExactBase = "morphology.ible.exact-base.v1"
    }

    private struct MorphologyPolicy: Encodable {
        let identitySchemaVersion: Int
        let morphologyVersion: String
        let ruleIDs: [String]
        let suffixIPA: String
        let minimumBaseLength: Int
        let properNamePolicyVersion: String
        let baseEvidencePolicyVersion: String
        let exceptionSetSHA256: String
        let pronunciationPackVersion: String
        let kokoroVocabularyVersion: String
    }

    private struct Resolution {
        let ipa: String
        let source: PronunciationAuditDecision.Source
        let ruleID: String
        let rationale: String
        let candidateID: String
        let candidatePackVersion: String
        let derivationBase: String?
        let derivationRuleID: String?
    }

    private static let ordinaryBoundaryPunctuation: Set<Character> = [
        "\"", "“", "”", "(", ")", "[", "]", "{", "}", ",", ".", ";", ":",
        "!", "?",
    ]
    private static let contractionSuffixes = [
        "'d", "'ll", "'m", "n't", "'re", "'s", "'ve",
    ]

    static func morphologyCandidatePackVersion(
        for pack: EnglishPronunciationPack,
        ruleIDs: [String] = DerivationRule.allCases.map(\.rawValue),
        exceptionWords: Set<String> = exceptionWords,
        properNamePolicyVersion: String = properNamePolicyVersion,
        baseEvidencePolicyVersion: String = baseEvidencePolicyVersion
    ) -> String {
        guard let exceptionData = canonicalJSON(Array(exceptionWords).sorted()) else {
            return "\(morphologyVersion):sha256:" + String(repeating: "0", count: 64)
        }
        let payload = MorphologyPolicy(
            identitySchemaVersion: morphologyIdentitySchemaVersion,
            morphologyVersion: morphologyVersion,
            ruleIDs: ruleIDs.sorted(),
            suffixIPA: suffixIPA,
            minimumBaseLength: minimumBaseLength,
            properNamePolicyVersion: properNamePolicyVersion,
            baseEvidencePolicyVersion: baseEvidencePolicyVersion,
            exceptionSetSHA256: "sha256:\(sha256(exceptionData))",
            pronunciationPackVersion: pack.packVersion,
            kokoroVocabularyVersion: pack.kokoroVocabularyVersion)
        guard let payloadData = canonicalJSON(payload) else {
            return "\(morphologyVersion):sha256:" + String(repeating: "0", count: 64)
        }
        return "\(morphologyVersion):sha256:\(sha256(payloadData))"
    }

    static func derivedCandidateID(
        normalizedWord: String,
        derivationBase: String,
        derivationRuleID: String,
        baseIPA: String,
        derivedIPA: String,
        candidatePackVersion: String
    ) -> String {
        let fields = [
            candidatePackVersion, normalizedWord, derivationBase,
            derivationRuleID, baseIPA, derivedIPA,
        ]
        guard isNormalizedWord(normalizedWord),
            isNormalizedWord(derivationBase),
            fields.allSatisfy({ !$0.isEmpty && !$0.contains("\0") })
        else {
            return ""
        }
        let digest = sha256(Data(fields.joined(separator: "\0").utf8))
        return "morphology.\(normalizedWord).\(digest.prefix(12))"
    }

    static func rewrite(
        to text: String,
        blockID: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> PronunciationRewriteResult {
        // `.empty` is the explicit low-level/test and load-failure sentinel.
        // Universal policy fails closed unless a semantic pack snapshot exists.
        guard pack != .empty else {
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }
        let protectedRanges = NarrationTextChunker.pronunciationProtectedRanges(in: text)
            .map { NSRange($0, in: text) }
        let candidateRanges = lexicalTokenRanges(in: text).compactMap {
            candidateRange(in: $0, source: text)
        }
        var replacements:
            [(range: NSRange, sourceWord: String, resolution: Resolution,
              decisionSeed: PronunciationDecisionSeed)] = []

        for range in candidateRanges {
            let candidateRange = NSRange(range, in: text)
            guard !protectedRanges.contains(where: {
                NSIntersectionRange(candidateRange, $0).length > 0
            }),
                !range.isEmpty
            else {
                continue
            }
            let sourceWord = String(text[range])
            let canonicalSourceSpelling =
                PronunciationAuditContext.canonicalEnglishKeySpelling(sourceWord)
            let normalizedSpelling = canonicalSourceSpelling
            let isPossessive =
                canonicalSourceSpelling.hasSuffix("'s")
                || canonicalSourceSpelling.hasSuffix("'")
            let isContraction = contractionSuffixes.contains {
                canonicalSourceSpelling.hasSuffix($0)
            }
            guard !isPossessive,
                !isContraction,
                EnglishPronunciationPack.isValidNormalizedKey(normalizedSpelling),
                !contextualExclusions.contains(normalizedSpelling),
                !isProperNameRisk(
                    sourceWord: sourceWord,
                    sourceRange: range,
                    in: text)
            else {
                continue
            }
            let normalizedWord = normalizedSpelling

            let resolution: Resolution?
            if let candidate = pack.automaticCandidate(for: normalizedWord) {
                resolution = Resolution(
                    ipa: candidate.ipa,
                    source: .supplementalLexicon,
                    ruleID: "supplemental-lexicon.exact.v1",
                    rationale:
                        "Validated supplemental whole-word pronunciation selected for “\(sourceWord)”.",
                    candidateID: candidate.candidateID,
                    candidatePackVersion: pack.packVersion,
                    derivationBase: nil,
                    derivationRuleID: nil)
            } else {
                resolution = morphologyResolution(
                    normalizedWord: normalizedWord,
                    pack: pack,
                    basePronunciation: basePronunciation)
            }

            guard let resolution,
                let wordSpan = PronunciationAuditContext.wordSpan(
                    containing: range,
                    in: text)
            else {
                continue
            }
            replacements.append(
                (
                    range: candidateRange,
                    sourceWord: sourceWord,
                    resolution: resolution,
                    decisionSeed: PronunciationDecisionSeed(
                        blockID: blockID,
                        wordStart: wordSpan.lowerBound,
                        wordEnd: wordSpan.upperBound,
                        normalizedWord: normalizedWord,
                        sourceWord: sourceWord,
                        sourceContext: PronunciationAuditContext.sourceContext(
                            in: text,
                            wordStart: wordSpan.lowerBound,
                            wordEnd: wordSpan.upperBound),
                        selectedIPA: resolution.ipa,
                        source: resolution.source,
                        ruleID: resolution.ruleID,
                        rationale: resolution.rationale,
                        candidateID: resolution.candidateID,
                        candidatePackVersion: resolution.candidatePackVersion,
                        derivationBase: resolution.derivationBase,
                        derivationRuleID: resolution.derivationRuleID)
                ))
        }

        var result = text
        for replacement in replacements.reversed() {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(
                range,
                with: "[\(replacement.sourceWord)](/\(replacement.resolution.ipa)/)")
        }
        return PronunciationRewriteResult(
            text: result,
            decisionSeeds: replacements.map(\.decisionSeed))
    }

    /// Produces at most one complete candidate from a whitespace-delimited
    /// authored token. Ordinary punctuation may envelope the candidate. One
    /// balanced straight or typographic single-quote pair is also an envelope;
    /// unmatched, doubled, mismatched, or internal apostrophes remain part of
    /// the candidate and must pass lexical validation unchanged.
    private static func candidateRange(
        in tokenRange: NSRange,
        source: String
    ) -> Range<String.Index>? {
        guard var range = Range(tokenRange, in: source), !range.isEmpty else {
            return nil
        }
        let squareBrackets = source[range].filter { $0 == "[" || $0 == "]" }
        guard squareBrackets.isEmpty
            || squareBrackets == "[]"
            || isInsideBalancedEditorialBrackets(range, in: source)
        else {
            return nil
        }

        trimOrdinaryBoundaryPunctuation(from: &range, in: source)
        guard !range.isEmpty else { return nil }

        let first = source[range].first
        let last = source[range].last
        if (first == "'" && last == "'") || (first == "‘" && last == "’") {
            let quoteStart = source.index(after: range.lowerBound)
            let quoteEnd = source.index(before: range.upperBound)
            guard quoteStart <= quoteEnd else { return nil }
            range = quoteStart..<quoteEnd
            trimOrdinaryBoundaryPunctuation(from: &range, in: source)
        }
        return range.isEmpty ? nil : range
    }

    private static func trimOrdinaryBoundaryPunctuation(
        from range: inout Range<String.Index>,
        in source: String
    ) {
        while let first = source[range].first,
            ordinaryBoundaryPunctuation.contains(first)
        {
            range = source.index(after: range.lowerBound)..<range.upperBound
        }
        while let last = source[range].last,
            ordinaryBoundaryPunctuation.contains(last)
        {
            range = range.lowerBound..<source.index(before: range.upperBound)
        }
    }

    private static func isInsideBalancedEditorialBrackets(
        _ candidateRange: Range<String.Index>,
        in source: String
    ) -> Bool {
        var outerStart: String.Index?
        var depth = 0
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "\\" {
                let escaped = source.index(after: index)
                index =
                    escaped < source.endIndex
                    ? source.index(after: escaped)
                    : escaped
                continue
            }
            if source[index] == "[" {
                if depth == 0 { outerStart = index }
                depth += 1
            } else if source[index] == "]", depth > 0 {
                depth -= 1
                if depth == 0, let start = outerStart {
                    let upperBound = source.index(after: index)
                    let isConnectedMarkdown =
                        upperBound < source.endIndex
                        && (source[upperBound] == "[" || source[upperBound] == "(")
                    if !isConnectedMarkdown,
                        start <= candidateRange.lowerBound,
                        candidateRange.upperBound <= upperBound
                    {
                        return true
                    }
                    outerStart = nil
                }
            }
            index = source.index(after: index)
        }
        return false
    }

    /// Unicode-scalar whitespace bounds keep format controls attached to the
    /// authored token even when Swift grapheme clustering associates a leading
    /// joiner with the preceding whitespace character.
    private static func lexicalTokenRanges(in source: String) -> [NSRange] {
        let scalars = source.unicodeScalars
        var ranges: [NSRange] = []
        var tokenStart: String.Index?
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index].properties.isWhitespace {
                if let start = tokenStart {
                    ranges.append(NSRange(start..<index, in: source))
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = scalars.index(after: index)
        }
        if let tokenStart {
            ranges.append(NSRange(tokenStart..<scalars.endIndex, in: source))
        }
        return ranges
    }

    private static func morphologyResolution(
        normalizedWord: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> Resolution? {
        guard !exceptionWords.contains(normalizedWord),
            !pack.hasExplicitCandidate(for: normalizedWord)
        else {
            return nil
        }

        var eligibleBases: [(DerivationRule, String)] = []
        func appendEligible(_ rule: DerivationRule, base: String) {
            guard base.count >= minimumBaseLength,
                isNormalizedWord(base),
                !exceptionWords.contains(base),
                !contextualExclusions.contains(base)
            else {
                return
            }
            eligibleBases.append((rule, base))
        }

        if normalizedWord.hasSuffix("able") {
            let stem = String(normalizedWord.dropLast(4))
            appendEligible(.ableExactBase, base: stem)
            appendEligible(.ableSilentE, base: stem + "e")
        }
        if normalizedWord.hasSuffix("ible") {
            appendEligible(.ibleExactBase, base: String(normalizedWord.dropLast(4)))
        }
        guard !eligibleBases.isEmpty,
            basePronunciation(normalizedWord) == nil
        else {
            return nil
        }

        var candidates: [(DerivationRule, String, String)] = []
        for eligible in eligibleBases {
            guard let ipa = basePronunciation(eligible.1), !ipa.isEmpty else {
                continue
            }
            candidates.append((eligible.0, eligible.1, ipa))
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }

        let derivedIPA = candidate.2 + suffixIPA
        let policyVersion = morphologyCandidatePackVersion(for: pack)
        let candidateID = derivedCandidateID(
            normalizedWord: normalizedWord,
            derivationBase: candidate.1,
            derivationRuleID: candidate.0.rawValue,
            baseIPA: candidate.2,
            derivedIPA: derivedIPA,
            candidatePackVersion: policyVersion)
        guard !candidateID.isEmpty else { return nil }
        return Resolution(
            ipa: derivedIPA,
            source: .derivedMorphology,
            ruleID: candidate.0.rawValue,
            rationale:
                "Deterministic \(candidate.0.rawValue) derivation from validated base “\(candidate.1)”.",
            candidateID: candidateID,
            candidatePackVersion: policyVersion,
            derivationBase: candidate.1,
            derivationRuleID: candidate.0.rawValue)
    }

    private static func isProperNameRisk(
        sourceWord: String,
        sourceRange: Range<String.Index>,
        in text: String
    ) -> Bool {
        if sourceWord.count > 1, sourceWord.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return true
        }
        guard sourceWord.first?.isUppercase == true else { return false }
        let prefix = text[..<sourceRange.lowerBound]
        guard let boundary = prefix.lastIndex(where: { ".!?…\n\r".contains($0) })
        else {
            return prefix.contains { $0.isLetter || $0.isNumber }
        }
        let sentenceTail = prefix[prefix.index(after: boundary)...]
        if sentenceTail.contains(where: { $0.isLetter || $0.isNumber }) {
            return true
        }
        return prefix[boundary] == "." && isAmbiguousPeriod(boundary, in: text)
    }

    private static func isAmbiguousPeriod(
        _ period: String.Index,
        in text: String
    ) -> Bool {
        let beforePeriod = text[..<period]
        var tokenStart = beforePeriod.endIndex
        while tokenStart > beforePeriod.startIndex {
            let previous = beforePeriod.index(before: tokenStart)
            let character = beforePeriod[previous]
            guard character.isLetter || character.isNumber || character == "."
            else {
                break
            }
            tokenStart = previous
        }
        let token = String(beforePeriod[tokenStart...]).lowercased()
        guard !token.isEmpty else { return true }
        if ambiguousPeriodAbbreviations.contains(token) {
            return true
        }
        if token.count <= 3, token.allSatisfy(\.isLetter) {
            return true
        }

        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        if components.count == 1 {
            return token.count == 1 && token.first?.isLetter == true
        }
        return components.allSatisfy {
            $0.count == 1 && $0.first?.isLetter == true
        }
    }

    private static func isNormalizedWord(_ value: String) -> Bool {
        !value.isEmpty && value == value.lowercased()
            && value.allSatisfy(\.isLetter)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
