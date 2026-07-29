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
    static let properNamePolicyVersion = "proper-name-risk-v1"
    static let baseEvidencePolicyVersion = "kokoro-nonfallback-rating3-v1"
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

    private static let wordRegex = try! NSRegularExpression(
        pattern: #"\b[\p{L}]+(?:['’]s)?\b"#,
        options: [.caseInsensitive])
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[[^\]]+\]\(/[^/]*/\)"#)

    static func morphologyCandidatePackVersion(
        for pack: EnglishPronunciationPack,
        ruleIDs: [String] = DerivationRule.allCases.map(\.rawValue),
        exceptionWords: Set<String> = exceptionWords,
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
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let linkRanges = linkRegex.matches(in: text, range: fullRange).map(\.range)
        let matches = wordRegex.matches(in: text, range: fullRange)
        var replacements:
            [(range: NSRange, sourceWord: String, resolution: Resolution,
              decisionSeed: PronunciationDecisionSeed)] = []

        for match in matches {
            guard !linkRanges.contains(where: { NSLocationInRange(match.range.location, $0) }),
                let range = Range(match.range, in: text)
            else {
                continue
            }
            let sourceWord = String(text[range])
            let possessive = sourceWord.hasSuffix("'s") || sourceWord.hasSuffix("’s")
            let bareWord = possessive ? String(sourceWord.dropLast(2)) : sourceWord
            let normalizedWord = bareWord.lowercased()
            guard isNormalizedWord(normalizedWord),
                !possessive,
                !contextualExclusions.contains(normalizedWord),
                !isProperNameRisk(
                    sourceWord: bareWord,
                    sourceRange: range,
                    in: text)
            else {
                continue
            }

            let resolution: Resolution?
            if let candidate = pack.automaticCandidate(for: normalizedWord) {
                resolution = Resolution(
                    ipa: candidate.ipa,
                    source: .supplementalLexicon,
                    ruleID: "supplemental-lexicon.exact.v1",
                    rationale:
                        "Validated supplemental whole-word pronunciation selected for “\(bareWord)”.",
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
                    range: match.range,
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

    private static func morphologyResolution(
        normalizedWord: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> Resolution? {
        guard !exceptionWords.contains(normalizedWord),
            !pack.hasExplicitCandidate(for: normalizedWord),
            basePronunciation(normalizedWord) == nil
        else {
            return nil
        }

        var candidates: [(DerivationRule, String, String)] = []
        func append(_ rule: DerivationRule, base: String) {
            guard base.count >= minimumBaseLength,
                isNormalizedWord(base),
                !exceptionWords.contains(base),
                !contextualExclusions.contains(base),
                let ipa = basePronunciation(base),
                !ipa.isEmpty
            else {
                return
            }
            candidates.append((rule, base, ipa))
        }

        if normalizedWord.hasSuffix("able") {
            let stem = String(normalizedWord.dropLast(4))
            append(.ableExactBase, base: stem)
            append(.ableSilentE, base: stem + "e")
        }
        if normalizedWord.hasSuffix("ible") {
            append(.ibleExactBase, base: String(normalizedWord.dropLast(4)))
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
        let sentenceTail =
            prefix.lastIndex(where: { ".!?…;\n\r".contains($0) })
            .map { prefix[prefix.index(after: $0)...] }
            ?? prefix[prefix.startIndex...]
        return sentenceTail.contains { $0.isLetter || $0.isNumber }
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
