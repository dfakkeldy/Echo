// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import os.log

/// Immutable, fully validated view of Echo's bundled supplemental English
/// pronunciation data. No candidate is exposed until the complete manifest,
/// canonical entries digest, and semantic pack identity have been verified.
nonisolated struct EnglishPronunciationPack: Equatable, Sendable {
    /// The generated pack is currently about 22.9 MB. A fixed 32 MiB ceiling
    /// leaves controlled growth room while bounding mapped input, decoding,
    /// and canonical re-encoding work.
    static let maximumPackByteCount = 32 * 1_024 * 1_024
    fileprivate static let maximumEntryCount = 100_000
    fileprivate static let maximumCandidateCount = 120_000
    fileprivate static let maximumCandidatesPerEntry = 32
    fileprivate static let maximumSourceCount = 16
    fileprivate static let maximumLicenseCount = 16
    fileprivate static let maximumAcknowledgmentCount = 32
    fileprivate static let maximumGenerationReportCount = 1_000_000
    fileprivate static let maximumNormalizedWordByteCount = 128

    struct SourceSnapshot: Codable, Equatable, Sendable {
        let sourceID: String
        let snapshotID: String
        let role: String
        let sha256: String
    }

    struct LicenseRecord: Codable, Equatable, Sendable {
        let sourceID: String
        let licenseID: String
        let licensePath: String
    }

    struct GeneratorBehavior: Codable, Equatable, Sendable {
        let generatorVersion: String
        let normalizationPolicyVersion: String
        let arpabetMappingVersion: String
        let sourcePrecedencePolicyVersion: String
        let automaticSelectionPolicyVersion: String
        let candidateValidationPolicyVersion: String
    }

    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let lexicalClass: String?
        let senseLabel: String?
        let sourceID: String
        let sourceTier: String
        let kind: String
        let automaticWithoutContext: Bool
        let frequencyBand: FrequencyBand
        let validationStatus: CandidateValidationStatus

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case candidateID
            case ipa
            case lexicalClass
            case senseLabel
            case sourceID
            case sourceTier
            case kind
            case automaticWithoutContext
            case frequencyBand
            case validationStatus
        }

        init(
            candidateID: String,
            ipa: String,
            lexicalClass: String?,
            senseLabel: String?,
            sourceID: String,
            sourceTier: String,
            kind: String,
            automaticWithoutContext: Bool,
            frequencyBand: FrequencyBand,
            validationStatus: CandidateValidationStatus
        ) {
            self.candidateID = candidateID
            self.ipa = ipa
            self.lexicalClass = lexicalClass
            self.senseLabel = senseLabel
            self.sourceID = sourceID
            self.sourceTier = sourceTier
            self.kind = kind
            self.automaticWithoutContext = automaticWithoutContext
            self.frequencyBand = frequencyBand
            self.validationStatus = validationStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.lexicalClass),
                container.contains(.senseLabel)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: container.contains(.lexicalClass)
                        ? .senseLabel : .lexicalClass,
                    in: container,
                    debugDescription:
                        "Nullable pronunciation candidate keys must be explicit.")
            }
            candidateID = try container.decode(String.self, forKey: .candidateID)
            ipa = try container.decode(String.self, forKey: .ipa)
            lexicalClass = try container.decodeIfPresent(String.self, forKey: .lexicalClass)
            senseLabel = try container.decodeIfPresent(String.self, forKey: .senseLabel)
            sourceID = try container.decode(String.self, forKey: .sourceID)
            sourceTier = try container.decode(String.self, forKey: .sourceTier)
            kind = try container.decode(String.self, forKey: .kind)
            automaticWithoutContext = try container.decode(
                Bool.self,
                forKey: .automaticWithoutContext)
            frequencyBand = try container.decode(FrequencyBand.self, forKey: .frequencyBand)
            validationStatus = try container.decode(
                CandidateValidationStatus.self,
                forKey: .validationStatus)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(candidateID, forKey: .candidateID)
            try container.encode(ipa, forKey: .ipa)
            if let lexicalClass {
                try container.encode(lexicalClass, forKey: .lexicalClass)
            } else {
                try container.encodeNil(forKey: .lexicalClass)
            }
            if let senseLabel {
                try container.encode(senseLabel, forKey: .senseLabel)
            } else {
                try container.encodeNil(forKey: .senseLabel)
            }
            try container.encode(sourceID, forKey: .sourceID)
            try container.encode(sourceTier, forKey: .sourceTier)
            try container.encode(kind, forKey: .kind)
            try container.encode(automaticWithoutContext, forKey: .automaticWithoutContext)
            try container.encode(frequencyBand, forKey: .frequencyBand)
            try container.encode(validationStatus, forKey: .validationStatus)
        }
    }

    enum FrequencyBand: String, Codable, Equatable, Sendable {
        case veryCommon
        case common
        case uncommon
        case rare
        case unknown
    }

    enum CandidateValidationStatus: String, Codable, Equatable, Sendable {
        case validatedAutomatic = "validated-automatic"
        case reportOnlyMissingSenseLabel = "report-only-missing-sense-label"
        case validatedHumanReviewed = "validated-human-reviewed"
    }

    let schemaVersion: Int
    let packVersion: String
    let generatorVersion: String
    let entryCount: Int
    let candidateCount: Int
    let normalizedDataSHA256: String
    let kokoroVocabularyVersion: String
    let generatorBehavior: GeneratorBehavior
    let dialect: String
    let sources: [SourceSnapshot]
    let licenses: [LicenseRecord]
    let requiredAcknowledgments: [String]
    let generationTimestamp: String
    private let entries: [String: [Candidate]]

    init(data: Data) throws {
        guard data.count <= Self.maximumPackByteCount else {
            throw ValidationError.invalid("input size")
        }
        try StrictPackJSONValidator.validate(data)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try Self.validate(manifest)

        schemaVersion = manifest.schemaVersion
        packVersion = manifest.packVersion
        generatorVersion = manifest.generatorVersion
        entryCount = manifest.entryCount
        candidateCount = manifest.candidateCount
        normalizedDataSHA256 = manifest.normalizedDataSHA256
        kokoroVocabularyVersion = manifest.kokoroVocabularyVersion
        generatorBehavior = manifest.semanticIdentityPayload.generatorBehavior
        dialect = manifest.dialect
        sources = manifest.sources
        licenses = manifest.licenses
        requiredAcknowledgments = manifest.requiredAcknowledgments
        generationTimestamp = manifest.generationTimestamp
        entries = manifest.entries
    }

    static let empty = EnglishPronunciationPack(
        schemaVersion: 1,
        packVersion: "unavailable-v1",
        generatorVersion: "unavailable-v1",
        entryCount: 0,
        candidateCount: 0,
        normalizedDataSHA256:
            "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
        kokoroVocabularyVersion: "unavailable-v1",
        generatorBehavior: GeneratorBehavior(
            generatorVersion: "unavailable-v1",
            normalizationPolicyVersion: "unavailable-v1",
            arpabetMappingVersion: "unavailable-v1",
            sourcePrecedencePolicyVersion: "unavailable-v1",
            automaticSelectionPolicyVersion: "unavailable-v1",
            candidateValidationPolicyVersion: "unavailable-v1"),
        dialect: "en-US",
        sources: [],
        licenses: [],
        requiredAcknowledgments: [],
        generationTimestamp: "1970-01-01T00:00:00Z",
        entries: [:])

    /// Resolves, maps, parses, and hashes the bundled pack on the global
    /// concurrent executor even when called by a MainActor owner.
    @concurrent
    static func bundledOrEmpty() async -> EnglishPronunciationPack {
        guard let url = NarrationResources.url(
            forResource: "us_pronunciation_pack",
            withExtension: "json")
        else {
            Logger(category: "PronunciationPack").error(
                "Bundled pronunciation pack unavailable: missing")
            return .empty
        }

        do {
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                let fileSize = values.fileSize,
                fileSize >= 0,
                fileSize <= Self.maximumPackByteCount
            else {
                throw ValidationError.invalid("resource size")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Self.maximumPackByteCount else {
                throw ValidationError.invalid("resource size")
            }
            return try EnglishPronunciationPack(data: data)
        } catch {
            Logger(category: "PronunciationPack").error(
                "Bundled pronunciation pack unavailable: invalid")
            return .empty
        }
    }

    func automaticCandidate(for normalizedWord: String) -> Candidate? {
        guard Self.isNormalizedWord(normalizedWord),
            let candidates = entries[normalizedWord],
            candidates.count == 1,
            let candidate = candidates.first,
            candidate.validationStatus == .validatedAutomatic,
            candidate.automaticWithoutContext
        else {
            return nil
        }
        return candidate
    }

    /// True when the supplemental source has any explicit whole-word record,
    /// including an inert ambiguous entry. Morphology must abstain rather than
    /// infer around a source candidate it is not authorized to choose.
    func hasExplicitCandidate(for normalizedWord: String) -> Bool {
        guard Self.isNormalizedWord(normalizedWord) else { return false }
        return entries[normalizedWord]?.isEmpty == false
    }

    /// Shared validated-key grammar for runtime lookup boundaries.
    static func isValidNormalizedKey(_ value: String) -> Bool {
        isNormalizedWord(value)
    }

    /// Controlled semantic fixture construction for pure resolver/cache tests.
    /// Production loading always goes through the fully validating `init(data:)`.
    static func emptyForTesting(
        packVersion: String,
        kokoroVocabularyVersion: String,
        generationTimestamp: String = "1970-01-01T00:00:00Z",
        automaticEntries: [String: (candidateID: String, ipa: String)] = [:],
        ambiguousWords: Set<String> = []
    ) -> EnglishPronunciationPack {
        var fixtureEntries: [String: [Candidate]] = [:]
        for (word, value) in automaticEntries {
            fixtureEntries[word] = [
                Candidate(
                    candidateID: value.candidateID,
                    ipa: value.ipa,
                    lexicalClass: nil,
                    senseLabel: nil,
                    sourceID: "fixture",
                    sourceTier: "supplemental",
                    kind: "explicit",
                    automaticWithoutContext: true,
                    frequencyBand: .unknown,
                    validationStatus: .validatedAutomatic)
            ]
        }
        for word in ambiguousWords {
            fixtureEntries[word] = [
                Candidate(
                    candidateID: "fixture.\(word).a",
                    ipa: "a",
                    lexicalClass: nil,
                    senseLabel: nil,
                    sourceID: "fixture",
                    sourceTier: "supplemental",
                    kind: "explicit",
                    automaticWithoutContext: false,
                    frequencyBand: .unknown,
                    validationStatus: .reportOnlyMissingSenseLabel),
                Candidate(
                    candidateID: "fixture.\(word).b",
                    ipa: "b",
                    lexicalClass: nil,
                    senseLabel: nil,
                    sourceID: "fixture",
                    sourceTier: "supplemental",
                    kind: "explicit",
                    automaticWithoutContext: false,
                    frequencyBand: .unknown,
                    validationStatus: .reportOnlyMissingSenseLabel),
            ]
        }
        let count = fixtureEntries.values.reduce(0) { $0 + $1.count }
        return EnglishPronunciationPack(
            schemaVersion: 1,
            packVersion: packVersion,
            generatorVersion: "fixture-v1",
            entryCount: fixtureEntries.count,
            candidateCount: count,
            normalizedDataSHA256: "sha256:" + String(repeating: "0", count: 64),
            kokoroVocabularyVersion: kokoroVocabularyVersion,
            generatorBehavior: GeneratorBehavior(
                generatorVersion: "fixture-v1",
                normalizationPolicyVersion: "fixture-v1",
                arpabetMappingVersion: "fixture-v1",
                sourcePrecedencePolicyVersion: "fixture-v1",
                automaticSelectionPolicyVersion: "fixture-v1",
                candidateValidationPolicyVersion: "fixture-v1"),
            dialect: "en-US",
            sources: [],
            licenses: [],
            requiredAcknowledgments: [],
            generationTimestamp: generationTimestamp,
            entries: fixtureEntries)
    }

    private init(
        schemaVersion: Int,
        packVersion: String,
        generatorVersion: String,
        entryCount: Int,
        candidateCount: Int,
        normalizedDataSHA256: String,
        kokoroVocabularyVersion: String,
        generatorBehavior: GeneratorBehavior,
        dialect: String,
        sources: [SourceSnapshot],
        licenses: [LicenseRecord],
        requiredAcknowledgments: [String],
        generationTimestamp: String,
        entries: [String: [Candidate]]
    ) {
        self.schemaVersion = schemaVersion
        self.packVersion = packVersion
        self.generatorVersion = generatorVersion
        self.entryCount = entryCount
        self.candidateCount = candidateCount
        self.normalizedDataSHA256 = normalizedDataSHA256
        self.kokoroVocabularyVersion = kokoroVocabularyVersion
        self.generatorBehavior = generatorBehavior
        self.dialect = dialect
        self.sources = sources
        self.licenses = licenses
        self.requiredAcknowledgments = requiredAcknowledgments
        self.generationTimestamp = generationTimestamp
        self.entries = entries
    }
}

extension EnglishPronunciationPack {
    static let contentDefaultPolicyVersion = "content-default-material-noun-v1"

    var productionPolicySignature: String {
        productionPolicySignature(
            contentDefaultPolicyVersion: Self.contentDefaultPolicyVersion)
    }

    func productionPolicySignature(contentDefaultPolicyVersion: String) -> String {
        [
            packVersion,
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: self),
            contentDefaultPolicyVersion,
        ].joined(separator: "|")
    }

    /// Words that name a candidate's POSITION rather than its meaning.
    ///
    /// `rank` is a member again. It was removed to rescue `rank 8` for `organ`
    /// -- an organ rank is a real register -- but removal was the wrong
    /// instrument, and it leaked in the false-ACCEPT direction. The refusal
    /// rule fires only when EVERY token is ordering vocabulary, so taking one
    /// word out of the set exempts every label built from it: bare `rank` and
    /// `rank two` became admissible while bare `form`, `reading`, `no` and
    /// `variant` stayed refused, which is an asymmetry with no basis in what
    /// the labels mean. `rank` on its own names ordering exactly as `variant`
    /// does.
    ///
    /// Every word here is dual-use to some degree -- a `verb form`, a `close
    /// reading`, an organ `rank` -- and dual-use is handled by the rule rather
    /// than by set membership: a content token beside the ordering word rescues
    /// the label, so `verb form` is admissible while `form` is not. Membership
    /// says only "this word contributes no meaning by itself".
    nonisolated static let senseLabelOrderTokens: Set<String> = [
        "alt", "alternate", "alternative", "candidate", "entry", "form",
        "index", "item", "no", "num", "number", "option", "order", "pron",
        "pronunciation", "rank", "reading", "sense", "variant", "version",
    ]

    /// Ordering words whose companion INTEGER designates a real thing rather
    /// than a position.
    ///
    /// This is the one property that separates `rank 8` (admissible, an organ
    /// register named by pipe length) from `variant 2` (inadmissible, a source
    /// index). Both are `<ordering word> <bare integer>`, so no rule phrased
    /// over token CLASSES can tell them apart -- the difference is lexical, and
    /// naming it here is what keeps it out of the rule as a special case.
    ///
    /// The criterion for membership: the word names a category whose members
    /// are conventionally identified BY number, so the numeral is data. Organ
    /// ranks are 8', 16', 4'. `form`, `reading`, `no` and `variant` are
    /// deliberately NOT members: their numeric companion is always an index
    /// (`form 2`, `reading 2`, `no. 3`, `variant 2` are ordering artifacts, and
    /// `variant 2` is pinned inadmissible), so admitting integers beside them
    /// would reopen the false-accept leak this closes. Their dual-use readings
    /// are already served by the content-token rule.
    ///
    /// Membership changes nothing about the bare word or a spelled companion.
    /// `rank`, `rank two` and `rank second` are refused exactly as `variant`,
    /// `variant two` and `variant second` are.
    nonisolated static let senseLabelDesignationNouns: Set<String> = [
        "rank",
    ]

    nonisolated static let senseLabelOrdinalSuffixes: Set<String> = [
        "st", "nd", "rd", "th",
    ]

    /// An ordinal spelled out is the same artifact as `2nd`.
    nonisolated static let senseLabelSpelledOrdinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth",
        "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth", "twentieth",
    ]

    /// A cardinal spelled out is the same artifact as `2`.
    nonisolated static let senseLabelSpelledNumbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]

    /// Determiners and prepositions carry no sense on their own, so they
    /// neither rescue an otherwise ordinal label (`the 2nd`) nor condemn one
    /// that has real content beside them (`a written account`).
    nonisolated static let senseLabelFillerTokens: Set<String> = [
        "a", "an", "the", "of", "for",
    ]

    /// Inflected forms of the headword restate it rather than distinguishing
    /// a sense: `records` for `record`, `lives` for `live`.
    nonisolated static let senseLabelInflectionSuffixes = [
        "s", "es", "ed", "d", "ing",
    ]

    /// Refuse labels that record a candidate's ordering or spelling instead of
    /// its sense.
    ///
    /// A sense label exists to tell two pronunciations of one spelling apart by
    /// meaning. An ordinal, a source-order token, a raw CMUdict alternate
    /// annotation, or a restatement of the headword conveys no meaning, so
    /// promoting one to a sense label manufactures the appearance of reviewed
    /// evidence out of ordering that was never reviewed. The specification says
    /// the generator "must not fabricate labels or ordinal strings", and a
    /// `validated-human-reviewed` candidate is admitted to contextual model
    /// selection, so this is the boundary that keeps that admission honest.
    ///
    /// Length and non-emptiness alone were the entire check before, and no test
    /// exercised even that: the committed pack contains zero
    /// `validated-human-reviewed` candidates, so the branch guarding them never
    /// executed.
    ///
    /// Two of the five prohibitions in brief 10.1 are NOT decidable here and
    /// are deliberately not attempted. A model-authored label is a provenance
    /// question -- the string carries no evidence of its author -- and must be
    /// answered by the source and review record. A label copied from another
    /// source's gloss is likewise indistinguishable from an original one.
    ///
    /// The refusal is a property of the label's TOKENS, never of how many it
    /// has. An earlier revision gated the ordinal rule on a one-token label
    /// and the order-token rule on a two-token one, so the check accepted
    /// combinations of things it individually refused -- `2nd variant`, `the
    /// 2nd`, `variant two` -- while over-refusing `rank 8`, a real organ
    /// register, because it matched the two-token shape. Both failures had one
    /// cause, so both are fixed by scanning every token instead of counting
    /// them.
    ///
    /// `rank 8` is rescued by `senseLabelDesignationNouns`, not by exempting
    /// `rank` from the ordering vocabulary. Exempting it was the previous
    /// attempt and it leaked the other way, admitting bare `rank` and `rank
    /// two`, because the refusal needs EVERY token to be ordering vocabulary
    /// and a non-member token satisfies nothing. The rescue is therefore an
    /// explicit narrow admission of `<designation noun> <integer>` rather than
    /// a hole in the vocabulary, which keeps the bare and spelled-companion
    /// cases refused for `rank` exactly as they are for `variant`.
    ///
    /// Deliberately module-internal rather than fileprivate: brief 10.1 states
    /// this rule, so the Task 10 acceptance suite asserts it directly instead
    /// of inferring it from a decode failure.
    nonisolated static func isAdmissibleSenseLabel(
        _ value: String,
        for word: String
    ) -> Bool {
        guard isShortSenseLabel(value) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        // No letter anywhere means no sense: "2", "(2)", "#2", "02".
        guard lowercased.contains(where: \.isLetter) else { return false }

        // A raw CMUdict alternate annotation: "example(2)".
        if lowercased.hasSuffix(")"), let open = lowercased.firstIndex(of: "(") {
            let inside = lowercased[
                lowercased.index(after: open)..<lowercased.index(
                    before: lowercased.endIndex)
            ]
            if !inside.isEmpty, inside.allSatisfy(\.isNumber) {
                return false
            }
        }

        // SCAN EVERY TOKEN. Both rules here previously gated on the label's
        // token COUNT -- the ordinal test on `parts.count == 1`, the
        // order-token test on `tokens.count == 2` -- so ADDING a token walked
        // out of both, and the check accepted combinations of things it
        // individually refused: `2nd` was refused but `2nd variant` accepted,
        // `variant 2` refused but `variant` alone accepted.
        //
        // The rule is now a property of the tokens rather than of their
        // number: a label is an ordering artifact when EVERY token is ordering
        // vocabulary. "Every" rather than "any" is what stops it
        // over-rejecting -- `verb form` and `rank 8` each pair an ordering
        // word with a content word and still name a sense. The shape-based
        // version got that wrong in both directions at once.
        //
        // Tokenized from the trimmed original rather than the lowercased copy
        // so that roman-numeral casing survives; each check lowercases what it
        // needs.
        let rawTokens = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if !rawTokens.isEmpty,
            rawTokens.allSatisfy(isSenseLabelOrderingToken),
            !isSenseLabelNumericDesignation(rawTokens)
        {
            return false
        }

        // A restatement of the headword distinguishes nothing, and neither
        // does an inflected form of it: `records` for `record` was previously
        // admissible because only exact equality was checked.
        let labelLetters = String(lowercased.filter(\.isLetter))
        let wordLetters = String(word.lowercased().filter(\.isLetter))
        if !labelLetters.isEmpty, !wordLetters.isEmpty,
            isHeadwordRestatement(labelLetters, of: wordLetters)
        {
            return false
        }

        return true
    }

    /// A designation noun qualified by a bare integer, as `rank 8` is.
    ///
    /// Phrased over token PROPERTIES, not over a token count, for the reason
    /// the shape-based version failed: `rank 8 16` and `the rank 8` are the
    /// same claim as `rank 8`, and a `count == 2` test would split them
    /// arbitrarily. Fillers neither rescue nor condemn, matching
    /// `senseLabelFillerTokens`, so they are skipped rather than counted.
    ///
    /// Both flags are required. Without a designation noun this would admit
    /// bare numerals, which carry no letter and are refused earlier anyway;
    /// without an integer it would admit bare `rank`, which is the false accept
    /// being closed. A SPELLED companion is not an integer, so `rank two` stays
    /// refused -- the numeral has to be data, and `two` is prose.
    ///
    /// A glued numeral is not a designation: `rank8` remains refused, because
    /// `<word><digits>` with no separator is the fabricated CMUdict artifact
    /// shape that `pron2` established, and reading it as a register would
    /// reopen that shape for every designation noun.
    nonisolated static func isSenseLabelNumericDesignation(
        _ tokens: [String]
    ) -> Bool {
        var sawDesignationNoun = false
        var sawInteger = false
        for token in tokens {
            let lowercased = token.lowercased()
            if senseLabelDesignationNouns.contains(lowercased) {
                sawDesignationNoun = true
                continue
            }
            if !lowercased.isEmpty, lowercased.allSatisfy(\.isNumber) {
                sawInteger = true
                continue
            }
            if senseLabelFillerTokens.contains(lowercased) { continue }
            return false
        }
        return sawDesignationNoun && sawInteger
    }

    /// A token that names ordering, either on its own or as a number glued to
    /// an order word (`pron2`).
    nonisolated static func isSenseLabelOrderingToken(_ raw: String) -> Bool {
        if isSenseLabelOrderingAtom(raw) { return true }
        let parts = splitBoundaryNumber(raw.lowercased())
        return parts.count > 1
            && parts.allSatisfy { !$0.isEmpty && isSenseLabelOrderingAtom($0) }
    }

    nonisolated static func isSenseLabelOrderingAtom(_ raw: String) -> Bool {
        let token = raw.lowercased()
        guard !token.isEmpty else { return false }
        if token.allSatisfy(\.isNumber) { return true }
        let digits = token.prefix(while: \.isNumber)
        if !digits.isEmpty,
            senseLabelOrdinalSuffixes.contains(
                String(token.dropFirst(digits.count)))
        {
            return true
        }
        if senseLabelOrderTokens.contains(token) { return true }
        if senseLabelSpelledOrdinals.contains(token) { return true }
        if senseLabelSpelledNumbers.contains(token) { return true }
        if senseLabelFillerTokens.contains(token) { return true }
        return isRomanNumeralSenseToken(raw)
    }

    /// Whether a token is written as a roman numeral.
    ///
    /// Membership in the roman alphabet is not sufficient: `mix` is a
    /// well-formed 1009, and `civil`, `did` and `mid` are all built from the
    /// same seven letters. Requiring conventional uppercase -- or a length no
    /// English word collides at -- keeps an ordinary word from being refused
    /// as an ordering artifact.
    nonisolated static func isRomanNumeralSenseToken(_ token: String) -> Bool {
        guard !token.isEmpty,
            token.allSatisfy({ "IVXLCDMivxlcdm".contains($0) })
        else {
            return false
        }
        guard token == token.uppercased() || token.count <= 2 else {
            return false
        }
        return isCanonicalRomanNumeral(token.uppercased())
    }

    nonisolated static func isCanonicalRomanNumeral(_ token: String) -> Bool {
        let groups: [[String]] = [
            ["M", "MM", "MMM"],
            ["C", "CC", "CCC", "CD", "D", "DC", "DCC", "DCCC", "CM"],
            ["X", "XX", "XXX", "XL", "L", "LX", "LXX", "LXXX", "XC"],
            ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"],
        ]
        var remainder = Substring(token)
        for group in groups {
            let longest = group
                .filter { remainder.hasPrefix($0) }
                .max(by: { $0.count < $1.count })
            if let longest { remainder = remainder.dropFirst(longest.count) }
        }
        return remainder.isEmpty
    }

    nonisolated static func isHeadwordRestatement(
        _ label: String,
        of word: String
    ) -> Bool {
        if label == word { return true }
        for suffix in senseLabelInflectionSuffixes {
            if label == word + suffix { return true }
            if word == label + suffix { return true }
        }
        // The stem drops `y` before `ies`: `study` -> `studies`.
        if label.hasSuffix("ies"), word.hasSuffix("y"),
            label.dropLast(3) == word.dropLast(1)
        {
            return true
        }
        if word.hasSuffix("ies"), label.hasSuffix("y"),
            word.dropLast(3) == label.dropLast(1)
        {
            return true
        }
        return false
    }

    nonisolated static func splitBoundaryNumber(_ value: String) -> [String] {
        let leading = value.prefix(while: \.isNumber)
        if !leading.isEmpty {
            return [String(leading), String(value.dropFirst(leading.count))]
        }
        let trailing = String(value.reversed().prefix(while: \.isNumber).reversed())
        if !trailing.isEmpty {
            return [String(value.dropLast(trailing.count)), trailing]
        }
        return [value]
    }
}

private extension EnglishPronunciationPack {
    nonisolated struct Manifest: Decodable {
        let schemaVersion: Int
        let packVersion: String
        let generatorVersion: String
        let entryCount: Int
        let candidateCount: Int
        let normalizedDataSHA256: String
        let kokoroVocabularyVersion: String
        let dialect: String
        let sources: [SourceSnapshot]
        let licenses: [LicenseRecord]
        let requiredAcknowledgments: [String]
        let generationTimestamp: String
        let semanticIdentityPayload: SemanticIdentityPayload
        let entries: [String: [Candidate]]
        let report: GenerationReport
    }

    nonisolated struct GenerationReport: Codable, Equatable {
        let existingGold: Int
        let existingSilver: Int
        let ambiguous: Int
        let incompatible: Int
        let imported: Int
    }

    nonisolated struct SourceProjection: Codable, Equatable {
        let sourceID: String
        let snapshotID: String
        let sha256: String
    }

    nonisolated struct SemanticIdentityPayload: Codable, Equatable {
        let identitySchemaVersion: Int
        let normalizedDataSHA256: String
        let sourceSnapshots: [SourceProjection]
        let generatorBehavior: GeneratorBehavior
        let kokoroVocabularyVersion: String
        let dialect: String
    }

    nonisolated enum ValidationError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let category):
                return "Invalid pronunciation pack: \(category)"
            }
        }
    }

    nonisolated static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ValidationError.invalid("schema")
        }
        guard manifest.dialect == "en-US" else {
            throw ValidationError.invalid("dialect")
        }
        guard isSHA256Identity(manifest.packVersion),
            isSHA256Identity(manifest.normalizedDataSHA256),
            isSHA256Identity(manifest.kokoroVocabularyVersion)
        else {
            throw ValidationError.invalid("digest")
        }
        guard isVersionIdentifier(manifest.generatorVersion),
            manifest.entryCount >= 0,
            manifest.candidateCount >= 0,
            manifest.entryCount <= maximumEntryCount,
            manifest.candidateCount <= maximumCandidateCount,
            isWholeSecondUTCTimestamp(manifest.generationTimestamp)
        else {
            throw ValidationError.invalid("manifest identity")
        }
        try validateGeneratorBehavior(manifest.semanticIdentityPayload.generatorBehavior)
        guard manifest.semanticIdentityPayload.identitySchemaVersion == 1 else {
            throw ValidationError.invalid("semantic identity schema")
        }

        guard manifest.sources.count <= maximumSourceCount,
            manifest.licenses.count <= maximumLicenseCount,
            manifest.requiredAcknowledgments.count <= maximumAcknowledgmentCount
        else {
            throw ValidationError.invalid("aggregate count")
        }
        let reportCounts = [
            manifest.report.existingGold,
            manifest.report.existingSilver,
            manifest.report.ambiguous,
            manifest.report.incompatible,
            manifest.report.imported,
        ]
        guard reportCounts.allSatisfy({
            (0...maximumGenerationReportCount).contains($0)
        }) else {
            throw ValidationError.invalid("generation report")
        }

        let sourceIDs = manifest.sources.map(\.sourceID)
        guard sourceIDs == sourceIDs.sorted(), Set(sourceIDs).count == sourceIDs.count else {
            throw ValidationError.invalid("source order")
        }
        for source in manifest.sources {
            guard isIdentifier(source.sourceID),
                isNonemptyBounded(source.snapshotID, maximum: 512),
                isVersionIdentifier(source.role),
                isSHA256Identity(source.sha256)
            else {
                throw ValidationError.invalid("source")
            }
        }

        guard !manifest.licenses.isEmpty,
            !manifest.requiredAcknowledgments.isEmpty,
            manifest.requiredAcknowledgments.allSatisfy({
                isNonemptyBounded($0, maximum: 512)
            })
        else {
            throw ValidationError.invalid("attribution")
        }
        var licensedSources = Set<String>()
        for license in manifest.licenses {
            guard Set(sourceIDs).contains(license.sourceID),
                licensedSources.insert(license.sourceID).inserted,
                isNonemptyBounded(license.licenseID, maximum: 128),
                isSafeRelativePath(license.licensePath)
            else {
                throw ValidationError.invalid("license")
            }
        }
        guard let cmudictLicense = manifest.licenses.first(where: {
            $0.sourceID == "cmudict"
        }),
            cmudictLicense.licenseID == "CMUdict-BSD-style",
            cmudictLicense.licensePath == "ThirdParty/CMUdict/LICENSE",
            manifest.requiredAcknowledgments == [
                "CMUdict notice bundled from THIRD_PARTY_NOTICES.md",
            ]
        else {
            throw ValidationError.invalid("CMUdict attribution")
        }

        guard manifest.entries.count <= maximumEntryCount,
            manifest.entryCount == manifest.entries.count
        else {
            throw ValidationError.invalid("entry count")
        }
        var seenCandidateIDs = Set<String>()
        var actualCandidateCount = 0
        for (word, candidates) in manifest.entries {
            guard isNormalizedWord(word),
                !candidates.isEmpty,
                candidates.count <= maximumCandidatesPerEntry
            else {
                throw ValidationError.invalid("entry")
            }
            actualCandidateCount += candidates.count
            guard actualCandidateCount <= maximumCandidateCount else {
                throw ValidationError.invalid("candidate count")
            }
            for candidate in candidates {
                guard isNonemptyBounded(candidate.candidateID, maximum: 256),
                    !candidate.candidateID.contains(where: \.isWhitespace),
                    seenCandidateIDs.insert(candidate.candidateID).inserted,
                    isNonemptyBounded(candidate.ipa, maximum: 256),
                    Set(sourceIDs).contains(candidate.sourceID),
                    candidate.sourceTier == "supplemental",
                    candidate.kind == "explicit",
                    candidate.lexicalClass.map({
                        isNonemptyBounded($0, maximum: 64)
                    }) ?? true
                else {
                    throw ValidationError.invalid("candidate")
                }
                try validateCandidate(
                    candidate,
                    entryCandidateCount: candidates.count,
                    word: word)
            }
        }
        guard manifest.candidateCount == actualCandidateCount else {
            throw ValidationError.invalid("candidate count")
        }
        let actualAmbiguousCount = manifest.entries.values.count {
            $0.count > 1
        }
        guard manifest.report.imported == manifest.entryCount,
            manifest.report.ambiguous == actualAmbiguousCount
        else {
            throw ValidationError.invalid("generation report")
        }

        let entriesDigest = "sha256:" + sha256Hex(try canonicalData(manifest.entries))
        guard entriesDigest == manifest.normalizedDataSHA256 else {
            throw ValidationError.invalid("entries digest")
        }

        let projectedSources = manifest.sources.map {
            SourceProjection(
                sourceID: $0.sourceID,
                snapshotID: $0.snapshotID,
                sha256: $0.sha256)
        }
        let reconstructedPayload = SemanticIdentityPayload(
            identitySchemaVersion: 1,
            normalizedDataSHA256: manifest.normalizedDataSHA256,
            sourceSnapshots: projectedSources,
            generatorBehavior: manifest.semanticIdentityPayload.generatorBehavior,
            kokoroVocabularyVersion: manifest.kokoroVocabularyVersion,
            dialect: manifest.dialect)
        guard reconstructedPayload == manifest.semanticIdentityPayload,
            manifest.generatorVersion
                == manifest.semanticIdentityPayload.generatorBehavior.generatorVersion,
            manifest.normalizedDataSHA256
                == manifest.semanticIdentityPayload.normalizedDataSHA256,
            manifest.kokoroVocabularyVersion
                == manifest.semanticIdentityPayload.kokoroVocabularyVersion,
            manifest.dialect == manifest.semanticIdentityPayload.dialect
        else {
            throw ValidationError.invalid("semantic projection")
        }

        let semanticVersion =
            "sha256:" + sha256Hex(try canonicalData(reconstructedPayload))
        guard semanticVersion == manifest.packVersion else {
            throw ValidationError.invalid("pack version")
        }
    }

    nonisolated static func validateCandidate(
        _ candidate: Candidate,
        entryCandidateCount: Int,
        word: String
    ) throws {
        switch candidate.validationStatus {
        case .validatedAutomatic:
            guard entryCandidateCount == 1, candidate.automaticWithoutContext else {
                throw ValidationError.invalid("automatic candidate")
            }
            if let senseLabel = candidate.senseLabel {
                guard isAdmissibleSenseLabel(senseLabel, for: word) else {
                    throw ValidationError.invalid("automatic sense label")
                }
            }
        case .reportOnlyMissingSenseLabel:
            guard entryCandidateCount > 1,
                candidate.senseLabel == nil,
                !candidate.automaticWithoutContext
            else {
                throw ValidationError.invalid("report-only candidate")
            }
        case .validatedHumanReviewed:
            guard let senseLabel = candidate.senseLabel,
                isAdmissibleSenseLabel(senseLabel, for: word),
                !candidate.automaticWithoutContext
            else {
                throw ValidationError.invalid("human-reviewed candidate")
            }
        }
    }


    nonisolated static func validateGeneratorBehavior(
        _ behavior: GeneratorBehavior
    ) throws {
        let versions = [
            behavior.generatorVersion,
            behavior.normalizationPolicyVersion,
            behavior.arpabetMappingVersion,
            behavior.sourcePrecedencePolicyVersion,
            behavior.automaticSelectionPolicyVersion,
            behavior.candidateValidationPolicyVersion,
        ]
        guard versions.allSatisfy(isVersionIdentifier) else {
            throw ValidationError.invalid("generator behavior")
        }
    }

    nonisolated static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isSHA256Identity(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        return PronunciationArtifactIntegrity.isLowercaseSHA256(
            String(value.dropFirst("sha256:".count)))
    }

    nonisolated static func isNormalizedWord(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= maximumNormalizedWordByteCount
        else {
            return false
        }
        var requiresLetter = true
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 97...122:
                requiresLetter = false
            case 39, 45:
                guard !requiresLetter else { return false }
                requiresLetter = true
            default:
                return false
            }
        }
        return !requiresLetter
    }

    nonisolated static func isIdentifier(_ value: String) -> Bool {
        isVersionIdentifier(value)
    }

    nonisolated static func isVersionIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    nonisolated static func isNonemptyBounded(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.count <= maximum
    }

    nonisolated static func isShortSenseLabel(_ value: String) -> Bool {
        isNonemptyBounded(value, maximum: 160)
    }

    nonisolated static func isSafeRelativePath(_ value: String) -> Bool {
        guard isNonemptyBounded(value, maximum: 512),
            !value.hasPrefix("/"),
            !value.contains("\\"),
            !value.split(separator: "/").contains("..")
        else {
            return false
        }
        return true
    }

    nonisolated static func isWholeSecondUTCTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 20,
            value.hasSuffix("Z")
        else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

/// A bounded, recursive JSON grammar walk performed before `JSONDecoder`.
///
/// Foundation keyed decoding is intentionally lossy for duplicate and unknown
/// object members. This scanner retains no value graph, but decodes each object
/// key (including escapes and surrogate pairs), rejects duplicates at every
/// nesting level, and enforces the exact object shapes that define pack
/// authority.
private nonisolated struct StrictPackJSONValidator {
    private enum Expectation {
        case any
        case integer
        case manifest
        case sources
        case source
        case licenses
        case license
        case acknowledgments
        case semanticIdentity
        case sourceSnapshots
        case sourceSnapshot
        case generatorBehavior
        case entries
        case candidates
        case candidate
        case report
    }

    private enum StructuralError: Error {
        case invalid
    }

    private static let maximumDepth = 64
    private static let maximumObjectKeyByteCount = 512

    private static let manifestKeys: Set<String> = [
        "schemaVersion",
        "packVersion",
        "generatorVersion",
        "entryCount",
        "candidateCount",
        "normalizedDataSHA256",
        "kokoroVocabularyVersion",
        "dialect",
        "sources",
        "licenses",
        "requiredAcknowledgments",
        "generationTimestamp",
        "semanticIdentityPayload",
        "entries",
        "report",
    ]
    private static let sourceKeys: Set<String> = [
        "sourceID", "snapshotID", "role", "sha256",
    ]
    private static let licenseKeys: Set<String> = [
        "sourceID", "licenseID", "licensePath",
    ]
    private static let semanticIdentityKeys: Set<String> = [
        "identitySchemaVersion",
        "normalizedDataSHA256",
        "sourceSnapshots",
        "generatorBehavior",
        "kokoroVocabularyVersion",
        "dialect",
    ]
    private static let sourceSnapshotKeys: Set<String> = [
        "sourceID", "snapshotID", "sha256",
    ]
    private static let generatorBehaviorKeys: Set<String> = [
        "generatorVersion",
        "normalizationPolicyVersion",
        "arpabetMappingVersion",
        "sourcePrecedencePolicyVersion",
        "automaticSelectionPolicyVersion",
        "candidateValidationPolicyVersion",
    ]
    private static let candidateKeys: Set<String> = [
        "candidateID",
        "ipa",
        "lexicalClass",
        "senseLabel",
        "sourceID",
        "sourceTier",
        "kind",
        "automaticWithoutContext",
        "frequencyBand",
        "validationStatus",
    ]
    private static let reportKeys: Set<String> = [
        "existingGold", "existingSilver", "ambiguous", "incompatible", "imported",
    ]

    private let data: Data
    private var index: Data.Index
    private var scannedEntryCount = 0
    private var scannedCandidateCount = 0

    private init(data: Data) {
        self.data = data
        index = data.startIndex
    }

    static func validate(_ data: Data) throws {
        var scanner = StrictPackJSONValidator(data: data)
        try scanner.parseValue(expecting: .manifest, depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == data.endIndex else {
            throw StructuralError.invalid
        }
    }

    private mutating func parseValue(
        expecting expectation: Expectation,
        depth: Int
    ) throws {
        guard depth <= Self.maximumDepth else {
            throw StructuralError.invalid
        }
        skipWhitespace()
        guard let byte = peek() else {
            throw StructuralError.invalid
        }
        switch byte {
        case 0x7B:
            try parseObject(expecting: expectation, depth: depth)
        case 0x5B:
            try parseArray(expecting: expectation, depth: depth)
        case 0x22:
            guard expectation == .any else {
                throw StructuralError.invalid
            }
            _ = try parseString(decoding: false)
        case 0x74:
            guard expectation == .any else {
                throw StructuralError.invalid
            }
            try consumeLiteral("true")
        case 0x66:
            guard expectation == .any else {
                throw StructuralError.invalid
            }
            try consumeLiteral("false")
        case 0x6E:
            guard expectation == .any else {
                throw StructuralError.invalid
            }
            try consumeLiteral("null")
        case 0x2D, 0x30...0x39:
            switch expectation {
            case .any:
                try parseNumber()
            case .integer:
                try parseInteger()
            default:
                throw StructuralError.invalid
            }
        default:
            throw StructuralError.invalid
        }
    }

    private mutating func parseObject(
        expecting expectation: Expectation,
        depth: Int
    ) throws {
        guard Self.isObjectExpectation(expectation) else {
            throw StructuralError.invalid
        }
        try consume(0x7B)
        skipWhitespace()
        var keys = Set<String>()
        if consumeIfPresent(0x7D) {
            try validate(keys: keys, for: expectation)
            return
        }

        while true {
            skipWhitespace()
            let key = try parseString(decoding: true)
            guard keys.insert(key).inserted else {
                throw StructuralError.invalid
            }
            if expectation == .entries {
                scannedEntryCount += 1
                guard scannedEntryCount <= EnglishPronunciationPack.maximumEntryCount
                else {
                    throw StructuralError.invalid
                }
            }
            guard Self.allowedKeys(for: expectation)?.contains(key) ?? true else {
                throw StructuralError.invalid
            }

            skipWhitespace()
            try consume(0x3A)
            try parseValue(
                expecting: Self.childExpectation(for: key, in: expectation),
                depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                break
            }
            try consume(0x2C)
        }
        try validate(keys: keys, for: expectation)
    }

    private mutating func parseArray(
        expecting expectation: Expectation,
        depth: Int
    ) throws {
        guard Self.isArrayExpectation(expectation) else {
            throw StructuralError.invalid
        }
        try consume(0x5B)
        skipWhitespace()
        var count = 0
        if consumeIfPresent(0x5D) {
            return
        }

        while true {
            count += 1
            try validateArrayCount(count, for: expectation)
            try parseValue(
                expecting: Self.elementExpectation(for: expectation),
                depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return
            }
            try consume(0x2C)
        }
    }

    private mutating func validateArrayCount(
        _ count: Int,
        for expectation: Expectation
    ) throws {
        switch expectation {
        case .sources, .sourceSnapshots:
            guard count <= EnglishPronunciationPack.maximumSourceCount else {
                throw StructuralError.invalid
            }
        case .licenses:
            guard count <= EnglishPronunciationPack.maximumLicenseCount else {
                throw StructuralError.invalid
            }
        case .acknowledgments:
            guard count <= EnglishPronunciationPack.maximumAcknowledgmentCount else {
                throw StructuralError.invalid
            }
        case .candidates:
            guard count <= EnglishPronunciationPack.maximumCandidatesPerEntry else {
                throw StructuralError.invalid
            }
            scannedCandidateCount += 1
            guard scannedCandidateCount
                <= EnglishPronunciationPack.maximumCandidateCount
            else {
                throw StructuralError.invalid
            }
        default:
            break
        }
    }

    private mutating func parseString(decoding: Bool) throws -> String {
        try consume(0x22)
        var output: [UInt8] = []

        while let byte = peek() {
            advance()
            switch byte {
            case 0x22:
                guard !decoding
                    || output.count <= Self.maximumObjectKeyByteCount,
                    let result = decoding
                        ? String(data: Data(output), encoding: .utf8)
                        : ""
                else {
                    throw StructuralError.invalid
                }
                return result
            case 0x00...0x1F:
                throw StructuralError.invalid
            case 0x5C:
                guard let escaped = peek() else {
                    throw StructuralError.invalid
                }
                advance()
                switch escaped {
                case 0x22, 0x5C, 0x2F:
                    if decoding { output.append(escaped) }
                case 0x62:
                    if decoding { output.append(0x08) }
                case 0x66:
                    if decoding { output.append(0x0C) }
                case 0x6E:
                    if decoding { output.append(0x0A) }
                case 0x72:
                    if decoding { output.append(0x0D) }
                case 0x74:
                    if decoding { output.append(0x09) }
                case 0x75:
                    let scalar = try parseUnicodeEscape()
                    if decoding {
                        output.append(contentsOf: String(scalar).utf8)
                    }
                default:
                    throw StructuralError.invalid
                }
            default:
                if decoding { output.append(byte) }
            }
            if decoding, output.count > Self.maximumObjectKeyByteCount {
                throw StructuralError.invalid
            }
        }
        throw StructuralError.invalid
    }

    private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
        let first = try parseHexQuad()
        let scalarValue: UInt32
        if (0xD800...0xDBFF).contains(first) {
            try consume(0x5C)
            try consume(0x75)
            let second = try parseHexQuad()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw StructuralError.invalid
            }
            scalarValue = 0x10000
                + (UInt32(first - 0xD800) << 10)
                + UInt32(second - 0xDC00)
        } else {
            guard !(0xDC00...0xDFFF).contains(first) else {
                throw StructuralError.invalid
            }
            scalarValue = UInt32(first)
        }
        guard let scalar = UnicodeScalar(scalarValue) else {
            throw StructuralError.invalid
        }
        return scalar
    }

    private mutating func parseHexQuad() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let digit = Self.hexValue(byte) else {
                throw StructuralError.invalid
            }
            advance()
            value = value * 16 + UInt16(digit)
        }
        return value
    }

    private mutating func parseNumber() throws {
        _ = consumeIfPresent(0x2D)
        guard let first = peek() else {
            throw StructuralError.invalid
        }
        if first == 0x30 {
            advance()
            if let next = peek(), (0x30...0x39).contains(next) {
                throw StructuralError.invalid
            }
        } else if (0x31...0x39).contains(first) {
            repeat { advance() } while peek().map {
                (0x30...0x39).contains($0)
            } == true
        } else {
            throw StructuralError.invalid
        }

        if consumeIfPresent(0x2E) {
            try consumeDigits()
        }
        if let byte = peek(), byte == 0x65 || byte == 0x45 {
            advance()
            if let sign = peek(), sign == 0x2B || sign == 0x2D {
                advance()
            }
            try consumeDigits()
        }
        if let byte = peek(),
            !Self.isWhitespace(byte),
            byte != 0x2C,
            byte != 0x5D,
            byte != 0x7D
        {
            throw StructuralError.invalid
        }
    }

    private mutating func parseInteger() throws {
        _ = consumeIfPresent(0x2D)
        guard let first = peek() else {
            throw StructuralError.invalid
        }
        if first == 0x30 {
            advance()
            if let next = peek(), (0x30...0x39).contains(next) {
                throw StructuralError.invalid
            }
        } else if (0x31...0x39).contains(first) {
            repeat { advance() } while peek().map {
                (0x30...0x39).contains($0)
            } == true
        } else {
            throw StructuralError.invalid
        }

        if let byte = peek(),
            !Self.isWhitespace(byte),
            byte != 0x2C,
            byte != 0x7D
        {
            throw StructuralError.invalid
        }
    }

    private mutating func consumeDigits() throws {
        var consumed = false
        while let byte = peek(), (0x30...0x39).contains(byte) {
            consumed = true
            advance()
        }
        guard consumed else {
            throw StructuralError.invalid
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            try consume(byte)
        }
        if let byte = peek(),
            !Self.isWhitespace(byte),
            byte != 0x2C,
            byte != 0x5D,
            byte != 0x7D
        {
            throw StructuralError.invalid
        }
    }

    private mutating func validate(
        keys: Set<String>,
        for expectation: Expectation
    ) throws {
        if let allowed = Self.allowedKeys(for: expectation), keys != allowed {
            throw StructuralError.invalid
        }
    }

    private static func allowedKeys(
        for expectation: Expectation
    ) -> Set<String>? {
        switch expectation {
        case .manifest: manifestKeys
        case .source: sourceKeys
        case .license: licenseKeys
        case .semanticIdentity: semanticIdentityKeys
        case .sourceSnapshot: sourceSnapshotKeys
        case .generatorBehavior: generatorBehaviorKeys
        case .candidate: candidateKeys
        case .report: reportKeys
        default: nil
        }
    }

    private static func childExpectation(
        for key: String,
        in expectation: Expectation
    ) -> Expectation {
        switch (expectation, key) {
        case (.manifest, "sources"): .sources
        case (.manifest, "licenses"): .licenses
        case (.manifest, "requiredAcknowledgments"): .acknowledgments
        case (.manifest, "semanticIdentityPayload"): .semanticIdentity
        case (.manifest, "entries"): .entries
        case (.manifest, "report"): .report
        case (.semanticIdentity, "sourceSnapshots"): .sourceSnapshots
        case (.semanticIdentity, "generatorBehavior"): .generatorBehavior
        case (.entries, _): .candidates
        case (.report, _): .integer
        default: .any
        }
    }

    private static func elementExpectation(
        for expectation: Expectation
    ) -> Expectation {
        switch expectation {
        case .sources: .source
        case .licenses: .license
        case .sourceSnapshots: .sourceSnapshot
        case .candidates: .candidate
        default: .any
        }
    }

    private static func isObjectExpectation(_ expectation: Expectation) -> Bool {
        switch expectation {
        case .any, .manifest, .source, .license, .semanticIdentity,
            .sourceSnapshot, .generatorBehavior, .entries, .candidate, .report:
            true
        default:
            false
        }
    }

    private static func isArrayExpectation(_ expectation: Expectation) -> Bool {
        switch expectation {
        case .any, .sources, .licenses, .acknowledgments, .sourceSnapshots,
            .candidates:
            true
        default:
            false
        }
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), Self.isWhitespace(byte) {
            advance()
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private func peek() -> UInt8? {
        guard index < data.endIndex else { return nil }
        return data[index]
    }

    private mutating func advance() {
        data.formIndex(after: &index)
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek() == expected else {
            throw StructuralError.invalid
        }
        advance()
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard peek() == expected else { return false }
        advance()
        return true
    }
}
