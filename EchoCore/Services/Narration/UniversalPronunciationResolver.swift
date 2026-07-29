// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Deterministic, context-free pronunciation enrichment applied after authored
/// overrides and before contextual homograph handling.
nonisolated enum UniversalPronunciationResolver {
    struct OperationCounts {
        var parserInspections = 0
        var protectedIntervalOperations = 0
        var properNameInspections = 0
        var auditSnapshotConstructions = 0

        var sourceTraversalOperations: Int {
            parserInspections
                + protectedIntervalOperations
                + properNameInspections
        }
    }

    static let morphologyVersion = "morphology-v1"
    static let morphologyIdentitySchemaVersion = 1
    static let suffixIPA = "əbəl"
    static let minimumBaseLength = 3
    static let properNamePolicyVersion = "proper-name-risk-v7"
    static let baseEvidencePolicyVersion = "kokoro-nonfallback-rating3-v1"
    /// Common honorific, military, professional, organizational, geographic,
    /// reference, and calendar abbreviations. A period after one of these is
    /// not sufficient evidence that the following capitalized token begins a
    /// new sentence.
    static let ambiguousPeriodAbbreviations: Set<String> = [
        "acad", "adm", "adv", "append", "apr", "approx", "ariz", "ark", "art",
        "assoc", "assn", "asst", "atty", "aug", "ave", "blvd", "br", "brig", "bros",
        "calif", "capt", "ch", "chap", "cmdr", "co", "col", "colo", "comm", "conn",
        "corp", "cpl", "ctr", "dec", "dept", "det", "dist", "div", "dr", "ens", "eq",
        "esq", "est", "etc", "exec", "exhib", "feb", "fig", "fr", "fri", "gen", "gov",
        "gysgt", "hon", "hwy", "ill", "inc", "insp", "intl", "jan", "jct", "jr", "jul",
        "jun", "ln", "lt", "ltd", "mass",
        "m.d", "maj", "mar", "messrs", "mlle", "mon", "mr", "mrs", "ms", "msgr",
        "msgt", "mt", "mx", "no", "nov", "oct", "ofc", "org", "penn", "pfc", "ph.d",
        "pkwy", "pl", "pp",
        "pres", "prof", "pvt", "rd", "rep", "rev", "rte", "sat", "sec", "sen", "sep",
        "sept", "sfc", "sgt", "spc", "sq", "sr", "ssgt", "st", "ste", "sun", "supt",
        "tenn", "terr", "thu", "thur", "thurs", "tue", "univ", "vol", "vs", "wed",
        "weds",
    ]
    static let contextualExclusions: Set<String> = [
        "content", "read", "live", "lives", "record", "records",
    ]
    static let exceptionWords: Set<String> = [
        "comfortable", "content", "livable", "live", "lives", "read",
        "readable", "record", "recordable", "records", "responsible",
    ]
    private static let maximumAmbiguousPeriodAbbreviationLength =
        ambiguousPeriodAbbreviations.map(\.count).max() ?? 0

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

    /// Candidate-start proper-name state built in one Unicode-scalar
    /// source-order pass, matching the index domain used by lexical tokens.
    /// Capitalization of each candidate is checked separately; this index owns
    /// only the preceding sentence-boundary context that was formerly rescanned
    /// from the candidate back to the start of the source.
    private struct ProperNameIndex {
        let riskByCandidateStart: [String.Index: Bool]
        let inspectionCount: Int

        init(
            source: String,
            candidateRanges: [Range<String.Index>]
        ) {
            let candidateStarts = candidateRanges.map(\.lowerBound)
            var candidateCursor = 0
            var risks: [String.Index: Bool] = [:]
            risks.reserveCapacity(candidateStarts.count)

            var hasAnyAlphanumeric = false
            var hasBoundary = false
            var boundaryTailHasAlphanumeric = false
            var lastBoundaryIsAmbiguousPeriod = false

            var tokenForCatalog = ""
            var tokenCanMatchCatalog = true
            var tokenCharacterCount = 0
            var tokenContainsOnlyLetters = true
            var tokenDotCount = 0
            var completedComponentsAreSingleLetters = true
            var currentComponentCharacterCount = 0
            var currentComponentContainsOnlyLetters = true
            var inspections = 0

            func resetPeriodToken() {
                tokenForCatalog = ""
                tokenCanMatchCatalog = true
                tokenCharacterCount = 0
                tokenContainsOnlyLetters = true
                tokenDotCount = 0
                completedComponentsAreSingleLetters = true
                currentComponentCharacterCount = 0
                currentComponentContainsOnlyLetters = true
            }

            func appendToPeriodToken(_ fragment: String) {
                for character in fragment {
                    inspections += 1
                    tokenCharacterCount += 1
                    tokenContainsOnlyLetters =
                        tokenContainsOnlyLetters && character.isLetter
                    currentComponentCharacterCount += 1
                    currentComponentContainsOnlyLetters =
                        currentComponentContainsOnlyLetters && character.isLetter
                    if tokenCanMatchCatalog {
                        tokenForCatalog.append(character)
                        if tokenCharacterCount
                            > UniversalPronunciationResolver
                                .maximumAmbiguousPeriodAbbreviationLength
                        {
                            tokenForCatalog = ""
                            tokenCanMatchCatalog = false
                        }
                    }
                }
            }

            func currentPeriodIsAmbiguous() -> Bool {
                if tokenCharacterCount == 0 {
                    return true
                }
                if tokenCanMatchCatalog,
                    UniversalPronunciationResolver
                        .ambiguousPeriodAbbreviations
                        .contains(tokenForCatalog)
                {
                    return true
                }
                if tokenCharacterCount <= 3, tokenContainsOnlyLetters {
                    return true
                }
                return tokenDotCount >= 1
                    && completedComponentsAreSingleLetters
                    && currentComponentCharacterCount == 1
                    && currentComponentContainsOnlyLetters
            }

            let sourceScalars = source.unicodeScalars
            var sourceIndex = sourceScalars.startIndex
            while sourceIndex < sourceScalars.endIndex {
                inspections += 1
                if candidateCursor < candidateStarts.count,
                    candidateStarts[candidateCursor] == sourceIndex
                {
                    let risk =
                        hasBoundary
                        ? boundaryTailHasAlphanumeric
                            || lastBoundaryIsAmbiguousPeriod
                        : hasAnyAlphanumeric
                    risks[sourceIndex] = risk
                    candidateCursor += 1
                }

                let scalar = sourceScalars[sourceIndex]
                let character = Character(String(scalar))
                if scalar.value == 0x2E {
                    hasBoundary = true
                    boundaryTailHasAlphanumeric = false
                    lastBoundaryIsAmbiguousPeriod =
                        currentPeriodIsAmbiguous()

                    completedComponentsAreSingleLetters =
                        completedComponentsAreSingleLetters
                        && currentComponentCharacterCount == 1
                        && currentComponentContainsOnlyLetters
                    currentComponentCharacterCount = 0
                    currentComponentContainsOnlyLetters = true
                    tokenDotCount += 1
                    inspections += 1
                    tokenCharacterCount += 1
                    tokenContainsOnlyLetters = false
                    if tokenCanMatchCatalog {
                        tokenForCatalog.append(".")
                        if tokenCharacterCount
                            > UniversalPronunciationResolver
                                .maximumAmbiguousPeriodAbbreviationLength
                        {
                            tokenForCatalog = ""
                            tokenCanMatchCatalog = false
                        }
                    }
                } else if scalar.value == 0x21
                    || scalar.value == 0x3F
                    || scalar.value == 0x2026
                    || scalar.value == 0x0A
                    || scalar.value == 0x0D
                {
                    hasBoundary = true
                    boundaryTailHasAlphanumeric = false
                    lastBoundaryIsAmbiguousPeriod = false
                    resetPeriodToken()
                } else if character.isLetter || character.isNumber {
                    hasAnyAlphanumeric = true
                    if hasBoundary {
                        boundaryTailHasAlphanumeric = true
                    }
                    appendToPeriodToken(character.lowercased())
                } else if tokenCharacterCount > 0,
                    scalar.properties.generalCategory == .nonspacingMark
                        || scalar.properties.generalCategory == .spacingMark
                        || scalar.properties.generalCategory == .enclosingMark
                {
                    tokenForCatalog = ""
                    tokenCanMatchCatalog = false
                } else {
                    resetPeriodToken()
                }
                sourceIndex = sourceScalars.index(after: sourceIndex)
            }

            riskByCandidateStart = risks
            inspectionCount = inspections
        }

        func isProperNameRisk(
            sourceWord: String,
            sourceRange: Range<String.Index>,
            inspectionCount: inout Int
        ) -> Bool {
            var characterCount = 0
            var isAllCaps = true
            var firstCharacter: Character?
            for character in sourceWord {
                inspectionCount += 1
                characterCount += 1
                if firstCharacter == nil {
                    firstCharacter = character
                }
                if character.isLetter, !character.isUppercase {
                    isAllCaps = false
                }
            }
            if characterCount > 1, isAllCaps {
                return true
            }
            guard firstCharacter?.isUppercase == true else {
                return false
            }
            return riskByCandidateStart[sourceRange.lowerBound] ?? true
        }
    }

    /// One immutable authored-to-display word map per resolver pass. Its link
    /// recognizer mirrors `MisakiPronunciationMarkup.link`, but uses precomputed
    /// next-delimiter indexes so malformed repeated brackets stay bounded.
    private struct AuditSnapshot {
        private struct Link {
            let range: Range<String.Index>
            let displayRange: Range<String.Index>
        }

        private static let contextRadius = 5

        let displayUTF16OffsetBySourceIndex: [String.Index: Int]
        let displayWordRanges: [NSRange]
        let displayWords: [String]

        init(source: String) {
            var nextClosingSquareByIndex: [String.Index: String.Index] = [:]
            var nextClosingParenthesisByIndex: [String.Index: String.Index] = [:]
            var nextClosingSquare: String.Index?
            var nextClosingParenthesis: String.Index?
            var reverseIndex = source.endIndex
            while reverseIndex > source.startIndex {
                reverseIndex = source.index(before: reverseIndex)
                if source[reverseIndex] == "]" {
                    nextClosingSquare = reverseIndex
                } else if source[reverseIndex] == ")" {
                    nextClosingParenthesis = reverseIndex
                }
                if let nextClosingSquare {
                    nextClosingSquareByIndex[reverseIndex] = nextClosingSquare
                }
                if let nextClosingParenthesis {
                    nextClosingParenthesisByIndex[reverseIndex] =
                        nextClosingParenthesis
                }
            }

            func link(startingAt start: String.Index) -> Link? {
                guard source[start] == "[" else { return nil }
                let displayStart = source.index(after: start)
                guard let displayEnd = nextClosingSquareByIndex[displayStart],
                    displayStart < displayEnd
                else {
                    return nil
                }
                let openParenthesis = source.index(after: displayEnd)
                guard openParenthesis < source.endIndex,
                    source[openParenthesis] == "("
                else {
                    return nil
                }
                let openingSlash = source.index(after: openParenthesis)
                guard openingSlash < source.endIndex,
                    source[openingSlash] == "/"
                else {
                    return nil
                }
                let ipaStart = source.index(after: openingSlash)
                guard let closeParenthesis =
                    nextClosingParenthesisByIndex[ipaStart],
                    ipaStart < closeParenthesis
                else {
                    return nil
                }
                let closingSlash = source.index(before: closeParenthesis)
                guard closingSlash > openingSlash,
                    source[closingSlash] == "/"
                else {
                    return nil
                }
                return Link(
                    range: start..<source.index(after: closeParenthesis),
                    displayRange: displayStart..<displayEnd)
            }

            var display = ""
            display.reserveCapacity(source.utf8.count)
            var offsets: [String.Index: Int] = [:]
            var displayUTF16Offset = 0
            var sourceIndex = source.startIndex
            while sourceIndex < source.endIndex {
                offsets[sourceIndex] = displayUTF16Offset
                if let link = link(startingAt: sourceIndex) {
                    let authoredDisplay = source[link.displayRange]
                    display.append(contentsOf: authoredDisplay)
                    displayUTF16Offset += authoredDisplay.utf16.count
                    sourceIndex = link.range.upperBound
                    offsets[sourceIndex] = displayUTF16Offset
                    continue
                }
                let character = source[sourceIndex]
                display.append(character)
                displayUTF16Offset += String(character).utf16.count
                sourceIndex = source.index(after: sourceIndex)
            }
            offsets[source.endIndex] = displayUTF16Offset

            displayUTF16OffsetBySourceIndex = offsets
            let ranges = WordTokenizer.wordRanges(in: display)
            displayWordRanges = ranges.map { NSRange($0, in: display) }
            displayWords = ranges.map { String(display[$0]) }
        }

        func wordSpan(
            containing sourceRange: Range<String.Index>
        ) -> ClosedRange<Int>? {
            guard let lower = displayUTF16OffsetBySourceIndex[sourceRange.lowerBound],
                let upper = displayUTF16OffsetBySourceIndex[sourceRange.upperBound],
                upper > lower
            else {
                return nil
            }
            let matchRange = NSRange(location: lower, length: upper - lower)

            var low = 0
            var high = displayWordRanges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(displayWordRanges[middle]) <= matchRange.location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let first = low
            guard first < displayWordRanges.count,
                displayWordRanges[first].location < NSMaxRange(matchRange)
            else {
                return nil
            }

            low = first
            high = displayWordRanges.count
            while low < high {
                let middle = (low + high) / 2
                if displayWordRanges[middle].location < NSMaxRange(matchRange) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return first...(low - 1)
        }

        func sourceContext(for wordSpan: ClosedRange<Int>) -> String {
            guard !displayWords.isEmpty,
                wordSpan.lowerBound >= 0,
                wordSpan.upperBound >= wordSpan.lowerBound,
                wordSpan.lowerBound < displayWords.count
            else {
                return ""
            }
            let boundedEnd = min(wordSpan.upperBound, displayWords.count - 1)
            let lower = max(0, wordSpan.lowerBound - Self.contextRadius)
            let upper = min(
                displayWords.count - 1,
                boundedEnd + Self.contextRadius)
            return displayWords[lower...upper].joined(separator: " ")
        }
    }

    private static let ordinaryBoundaryPunctuation: Set<Character> = [
        "\"", "“", "”", "(", ")", "[", "]", "{", "}", ",", ".", ";", ":",
        "!", "?",
    ]
    private static let contractionSuffixes = [
        "'d", "'ll", "'m", "n't", "'re", "'s", "'ve",
    ]

    /// Reuses the morphology resolver's versioned capitalization policy for
    /// other pronunciation discovery passes. Ranges must be in source order.
    static func properNameRiskFlags(
        in source: String,
        candidateRanges: [Range<String.Index>]
    ) -> [Bool] {
        guard !candidateRanges.isEmpty else { return [] }
        let index = ProperNameIndex(
            source: source,
            candidateRanges: candidateRanges)
        var inspectionCount = index.inspectionCount
        return candidateRanges.map { range in
            index.isProperNameRisk(
                sourceWord: String(source[range]),
                sourceRange: range,
                inspectionCount: &inspectionCount)
        }
    }

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
        basePronunciation: (String) -> String?,
        operationCounts: inout OperationCounts
    ) -> PronunciationRewriteResult {
        // `.empty` is the explicit low-level/test and load-failure sentinel.
        // Universal policy fails closed unless a semantic pack snapshot exists.
        guard pack != .empty else {
            operationCounts = OperationCounts()
            return PronunciationRewriteResult(text: text, decisionSeeds: [])
        }
        let syntaxIndex = NarrationTextChunker.pronunciationSyntaxIndex(
            in: text,
            inspectionCount: &operationCounts.parserInspections)
        var intervalOperations = 0
        var protectedIntervals = syntaxIndex.protectedRanges
            .map { NSRange($0, in: text) }
        protectedIntervals.sort {
            intervalOperations += 1
            if $0.location == $1.location {
                return $0.length > $1.length
            }
            return $0.location < $1.location
        }
        var mergedProtectedIntervals: [NSRange] = []
        mergedProtectedIntervals.reserveCapacity(protectedIntervals.count)
        for interval in protectedIntervals {
            intervalOperations += 1
            guard let last = mergedProtectedIntervals.last else {
                mergedProtectedIntervals.append(interval)
                continue
            }
            if interval.location <= NSMaxRange(last) {
                let upperBound = max(
                    NSMaxRange(last),
                    NSMaxRange(interval))
                mergedProtectedIntervals[mergedProtectedIntervals.count - 1] =
                    NSRange(
                        location: last.location,
                        length: upperBound - last.location)
            } else {
                mergedProtectedIntervals.append(interval)
            }
        }
        let candidateRanges = lexicalTokenRanges(in: text).compactMap {
            candidateRange(
                in: $0,
                source: text,
                editorialRangeByIndex: syntaxIndex.editorialRangeByIndex)
        }
        let properNameIndex = ProperNameIndex(
            source: text,
            candidateRanges: candidateRanges)
        operationCounts.properNameInspections =
            properNameIndex.inspectionCount
        let auditSnapshot = AuditSnapshot(source: text)
        operationCounts.auditSnapshotConstructions = 1
        var replacements:
            [(range: NSRange, sourceWord: String, resolution: Resolution,
              decisionSeed: PronunciationDecisionSeed)] = []

        var protectedIntervalCursor = 0
        for range in candidateRanges {
            let candidateRange = NSRange(range, in: text)
            while protectedIntervalCursor < mergedProtectedIntervals.count,
                NSMaxRange(mergedProtectedIntervals[protectedIntervalCursor])
                    <= candidateRange.location
            {
                intervalOperations += 1
                protectedIntervalCursor += 1
            }
            intervalOperations +=
                protectedIntervalCursor < mergedProtectedIntervals.count
                ? 1 : 0
            let isProtected =
                protectedIntervalCursor < mergedProtectedIntervals.count
                && NSIntersectionRange(
                    candidateRange,
                    mergedProtectedIntervals[protectedIntervalCursor]
                ).length > 0
            guard !isProtected, !range.isEmpty else {
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
                !properNameIndex.isProperNameRisk(
                    sourceWord: sourceWord,
                    sourceRange: range,
                    inspectionCount: &operationCounts.properNameInspections)
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
                let wordSpan = auditSnapshot.wordSpan(containing: range)
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
                        sourceContext: auditSnapshot.sourceContext(for: wordSpan),
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

        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex
        for replacement in replacements {
            guard let range = Range(replacement.range, in: text),
                cursor <= range.lowerBound
            else {
                continue
            }
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append(
                contentsOf:
                    "[\(replacement.sourceWord)](/\(replacement.resolution.ipa)/)")
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor...])
        operationCounts.protectedIntervalOperations =
            intervalOperations
        return PronunciationRewriteResult(
            text: result,
            decisionSeeds: replacements.map(\.decisionSeed))
    }

    static func rewrite(
        to text: String,
        blockID: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?,
        parserInspectionCount: inout Int,
        auditSnapshotConstructionCount: inout Int
    ) -> PronunciationRewriteResult {
        var operationCounts = OperationCounts()
        let result = rewrite(
            to: text,
            blockID: blockID,
            pack: pack,
            basePronunciation: basePronunciation,
            operationCounts: &operationCounts)
        parserInspectionCount = operationCounts.parserInspections
        auditSnapshotConstructionCount =
            operationCounts.auditSnapshotConstructions
        return result
    }

    static func rewrite(
        to text: String,
        blockID: String,
        pack: EnglishPronunciationPack,
        basePronunciation: (String) -> String?
    ) -> PronunciationRewriteResult {
        var parserInspectionCount = 0
        var auditSnapshotConstructionCount = 0
        return rewrite(
            to: text,
            blockID: blockID,
            pack: pack,
            basePronunciation: basePronunciation,
            parserInspectionCount: &parserInspectionCount,
            auditSnapshotConstructionCount: &auditSnapshotConstructionCount)
    }

    /// Produces at most one complete candidate from a whitespace-delimited
    /// authored token. Ordinary punctuation may envelope the candidate. One
    /// balanced straight or typographic single-quote pair is also an envelope;
    /// unmatched, doubled, mismatched, or internal apostrophes remain part of
    /// the candidate and must pass lexical validation unchanged.
    private static func candidateRange(
        in tokenRange: NSRange,
        source: String,
        editorialRangeByIndex: [String.Index: Range<String.Index>]
    ) -> Range<String.Index>? {
        guard var range = Range(tokenRange, in: source), !range.isEmpty else {
            return nil
        }
        let squareBrackets = source[range].filter { $0 == "[" || $0 == "]" }
        trimOrdinaryBoundaryPunctuation(from: &range, in: source)
        guard !range.isEmpty else { return nil }

        if !squareBrackets.isEmpty {
            guard let editorialRange = editorialRangeByIndex[range.lowerBound],
                range.upperBound <= editorialRange.upperBound
            else {
                return nil
            }
        }

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
