// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import os.log

/// Immutable, fully validated view of Echo's bundled supplemental English
/// pronunciation data. No candidate is exposed until the complete manifest,
/// canonical entries digest, and semantic pack identity have been verified.
nonisolated struct EnglishPronunciationPack: Equatable, Sendable {
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

    static func bundledOrEmpty() -> EnglishPronunciationPack {
        guard let url = NarrationResources.url(
            forResource: "us_pronunciation_pack",
            withExtension: "json")
        else {
            Logger(category: "PronunciationPack").error(
                "Bundled pronunciation pack unavailable: missing")
            return .empty
        }

        do {
            return try EnglishPronunciationPack(data: Data(contentsOf: url))
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
            isWholeSecondUTCTimestamp(manifest.generationTimestamp)
        else {
            throw ValidationError.invalid("manifest identity")
        }
        try validateGeneratorBehavior(manifest.semanticIdentityPayload.generatorBehavior)
        guard manifest.semanticIdentityPayload.identitySchemaVersion == 1 else {
            throw ValidationError.invalid("semantic identity schema")
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
            cmudictLicense.licensePath == "ThirdParty/CMUdict/LICENSE"
        else {
            throw ValidationError.invalid("CMUdict attribution")
        }

        guard manifest.entryCount == manifest.entries.count else {
            throw ValidationError.invalid("entry count")
        }
        var seenCandidateIDs = Set<String>()
        var actualCandidateCount = 0
        for (word, candidates) in manifest.entries {
            guard isNormalizedWord(word), !candidates.isEmpty else {
                throw ValidationError.invalid("entry")
            }
            actualCandidateCount += candidates.count
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
            guard candidate.senseLabel == nil, !candidate.automaticWithoutContext else {
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
        guard !value.isEmpty else { return false }
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
