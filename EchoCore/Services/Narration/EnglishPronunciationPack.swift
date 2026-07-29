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
    var productionPolicySignature: String {
        [
            packVersion,
            UniversalPronunciationResolver.morphologyCandidatePackVersion(for: self),
            "content-default-v1",
        ].joined(separator: "|")
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
                try validateCandidate(candidate, entryCandidateCount: candidates.count)
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
        entryCandidateCount: Int
    ) throws {
        switch candidate.validationStatus {
        case .validatedAutomatic:
            guard entryCandidateCount == 1, candidate.automaticWithoutContext else {
                throw ValidationError.invalid("automatic candidate")
            }
            if let senseLabel = candidate.senseLabel {
                guard isShortSenseLabel(senseLabel) else {
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
                isShortSenseLabel(senseLabel),
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
