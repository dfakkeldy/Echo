// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Immutable, validated disagreement evidence. This pack is intentionally
/// advisory-only: it exposes alternatives for inspection, never a selected
/// candidate or any production-policy identity.
nonisolated struct EnglishPronunciationAuditPack: Equatable, Sendable {
    static let maximumPackByteCount = 20 * 1_024 * 1_024
    private static let maximumEntryCount = 100_000
    private static let maximumCandidateCount = 150_000
    private static let maximumCandidatesPerEntry = 32

    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let sourceID: String
        let authority: String
        let validation: String
        let automaticEligible: Bool
    }

    private struct Entry: Codable, Equatable, Sendable {
        let normalizedWord: String
        let candidates: [Candidate]
    }

    private struct Source: Codable, Equatable, Sendable {
        let sourceID: String
        let snapshotID: String
        let role: String
        let sha256: String
    }

    private struct License: Codable, Equatable, Sendable {
        let sourceID: String
        let licenseID: String
        let licensePath: String
    }

    private struct SourceSnapshot: Codable, Equatable, Sendable {
        let sourceID: String
        let snapshotID: String
        let sha256: String
    }

    private struct GeneratorBehavior: Codable, Equatable, Sendable {
        let generatorVersion: String
        let normalizationPolicyVersion: String
        let arpabetMappingVersion: String
        let sourceComparisonPolicyVersion: String
        let automaticSelectionPolicyVersion: String
        let candidateValidationPolicyVersion: String
    }

    private struct SemanticIdentity: Codable, Equatable, Sendable {
        let identitySchemaVersion: Int
        let normalizedDataSHA256: String
        let sourceSnapshots: [SourceSnapshot]
        let generatorBehavior: GeneratorBehavior
        let kokoroVocabularyVersion: String
        let dialect: String
    }

    private struct Report: Codable, Equatable, Sendable {
        let overlaps: Int
        let disagreements: Int
        let incompatible: Int
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let auditPackVersion: String
        let generatorVersion: String
        let entryCount: Int
        let candidateCount: Int
        let normalizedDataSHA256: String
        let kokoroVocabularyVersion: String
        let dialect: String
        let sources: [Source]
        let licenses: [License]
        let requiredAcknowledgments: [String]
        let generationTimestamp: String
        let semanticIdentityPayload: SemanticIdentity
        let entries: [String: Entry]
        let report: Report
    }

    enum ValidationError: Error, Equatable {
        case invalid(String)
    }

    let schemaVersion: Int
    let auditPackVersion: String
    let entryCount: Int
    let candidateCount: Int
    private let entries: [String: Entry]

    init(data: Data) throws {
        guard data.count <= Self.maximumPackByteCount else {
            throw ValidationError.invalid("input size")
        }
        let root = try StrictAuditPackJSON.object(from: data)
        try Self.validateShape(root)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try Self.validate(manifest)

        schemaVersion = manifest.schemaVersion
        auditPackVersion = manifest.auditPackVersion
        entryCount = manifest.entryCount
        candidateCount = manifest.candidateCount
        entries = manifest.entries
    }

    static let empty = EnglishPronunciationAuditPack(
        schemaVersion: 1,
        auditPackVersion: "unavailable-v1",
        entryCount: 0,
        candidateCount: 0,
        entries: [:])

    @concurrent
    static func bundledOrEmpty() async -> EnglishPronunciationAuditPack {
        guard let url = NarrationResources.url(
            forResource: "us_pronunciation_audit_pack", withExtension: "json")
        else { return .empty }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                let size = values.fileSize,
                (0...Self.maximumPackByteCount).contains(size)
            else { return .empty }
            return try EnglishPronunciationAuditPack(
                data: Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            return .empty
        }
    }

    func alternatives(for normalizedWord: String) -> [Candidate] {
        guard Self.isNormalizedWord(normalizedWord) else { return [] }
        return entries[normalizedWord]?.candidates ?? []
    }

    private init(
        schemaVersion: Int,
        auditPackVersion: String,
        entryCount: Int,
        candidateCount: Int,
        entries: [String: Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.auditPackVersion = auditPackVersion
        self.entryCount = entryCount
        self.candidateCount = candidateCount
        self.entries = entries
    }

    private static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1,
            manifest.dialect == "en-US",
            isSHA256(manifest.auditPackVersion),
            isSHA256(manifest.normalizedDataSHA256),
            isSHA256(manifest.kokoroVocabularyVersion),
            isIdentifier(manifest.generatorVersion),
            isTimestamp(manifest.generationTimestamp),
            (0...maximumEntryCount).contains(manifest.entryCount),
            (0...maximumCandidateCount).contains(manifest.candidateCount)
        else { throw ValidationError.invalid("manifest") }

        let expectedSources = ["cmudict", "echo-us-gold", "echo-us-silver"]
        guard manifest.sources.map(\.sourceID) == expectedSources,
            manifest.sources.allSatisfy({
                isIdentifier($0.sourceID) && isIdentifier($0.role)
                    && isBounded($0.snapshotID, maximum: 512) && isSHA256($0.sha256)
            })
        else { throw ValidationError.invalid("sources") }

        let licenses = Set(manifest.licenses.map { "\($0.sourceID)|\($0.licenseID)|\($0.licensePath)" })
        guard licenses == Set([
            "cmudict|CMUdict-BSD-style|ThirdParty/CMUdict/LICENSE",
            "echo-us-gold|MisakiSwift-Apache-2.0|ThirdParty/MisakiSwift/LICENSE",
            "echo-us-silver|MisakiSwift-Apache-2.0|ThirdParty/MisakiSwift/LICENSE",
        ]), manifest.licenses.count == licenses.count,
            manifest.requiredAcknowledgments == [
                "CMUdict notice bundled from THIRD_PARTY_NOTICES.md",
                "MisakiSwift Apache-2.0 notice bundled from THIRD_PARTY_NOTICES.md",
            ]
        else { throw ValidationError.invalid("attribution") }

        let behavior = manifest.semanticIdentityPayload.generatorBehavior
        let sourceSnapshots = manifest.sources.map {
            SourceSnapshot(
                sourceID: $0.sourceID,
                snapshotID: $0.snapshotID,
                sha256: $0.sha256)
        }
        guard behavior.generatorVersion == manifest.generatorVersion,
            behavior.normalizationPolicyVersion == "english-key-normalization-v1",
            behavior.arpabetMappingVersion == "cmudict-arpabet-to-kokoro-v2",
            behavior.sourceComparisonPolicyVersion == "gold-silver-cmudict-disagreement-v1",
            behavior.automaticSelectionPolicyVersion == "advisory-only-shadow-v1",
            behavior.candidateValidationPolicyVersion == "strict-kokoro-vocabulary-v1",
            manifest.semanticIdentityPayload.identitySchemaVersion == 1,
            manifest.semanticIdentityPayload.normalizedDataSHA256 == manifest.normalizedDataSHA256,
            manifest.semanticIdentityPayload.kokoroVocabularyVersion == manifest.kokoroVocabularyVersion,
            manifest.semanticIdentityPayload.dialect == manifest.dialect,
            manifest.semanticIdentityPayload.sourceSnapshots == sourceSnapshots
        else { throw ValidationError.invalid("semantic identity") }

        guard manifest.entryCount == manifest.entries.count else {
            throw ValidationError.invalid("entry count")
        }
        let sourceIDs = Set(expectedSources)
        let vocabulary = try KokoroPhonemeVocab()
        var candidates = 0
        for (word, entry) in manifest.entries {
            guard word == entry.normalizedWord,
                isNormalizedWord(word),
                !entry.candidates.isEmpty,
                entry.candidates.count <= maximumCandidatesPerEntry
            else { throw ValidationError.invalid("entry") }
            for candidate in entry.candidates {
                guard isBounded(candidate.candidateID, maximum: 256),
                    !candidate.candidateID.contains(where: \.isWhitespace),
                    isBounded(candidate.ipa, maximum: 256),
                    sourceIDs.contains(candidate.sourceID),
                    candidate.authority == "uncertain",
                    candidate.validation == "shadow",
                    !candidate.automaticEligible
                else { throw ValidationError.invalid("candidate") }
                _ = try vocabulary.validatedIDs(forPhonemes: candidate.ipa)
            }
            candidates += entry.candidates.count
        }
        guard candidates == manifest.candidateCount,
            candidates <= maximumCandidateCount,
            manifest.report.disagreements == manifest.entryCount,
            manifest.report.overlaps >= manifest.report.disagreements,
            manifest.report.overlaps >= 0,
            manifest.report.disagreements >= 0,
            manifest.report.incompatible >= 0
        else { throw ValidationError.invalid("counts") }

        let entriesDigest = "sha256:" + sha256Hex(try canonicalData(manifest.entries))
        guard entriesDigest == manifest.normalizedDataSHA256 else {
            throw ValidationError.invalid("entries digest")
        }
        let semanticVersion = "sha256:" + sha256Hex(
            try canonicalData(manifest.semanticIdentityPayload))
        guard semanticVersion == manifest.auditPackVersion else {
            throw ValidationError.invalid("audit pack version")
        }
    }

    private static func validateShape(_ root: [String: Any]) throws {
        try exactKeys(root, [
            "schemaVersion", "auditPackVersion", "generatorVersion", "entryCount", "candidateCount",
            "normalizedDataSHA256", "kokoroVocabularyVersion", "dialect", "sources", "licenses",
            "requiredAcknowledgments", "generationTimestamp", "semanticIdentityPayload", "entries", "report",
        ])
        for source in try array(root, "sources") { try exactKeys(try object(source), ["sourceID", "snapshotID", "role", "sha256"]) }
        for license in try array(root, "licenses") { try exactKeys(try object(license), ["sourceID", "licenseID", "licensePath"]) }
        let identity = try object(root["semanticIdentityPayload"])
        try exactKeys(identity, ["identitySchemaVersion", "normalizedDataSHA256", "sourceSnapshots", "generatorBehavior", "kokoroVocabularyVersion", "dialect"])
        for source in try array(identity, "sourceSnapshots") { try exactKeys(try object(source), ["sourceID", "snapshotID", "sha256"]) }
        try exactKeys(try object(identity["generatorBehavior"]), ["generatorVersion", "normalizationPolicyVersion", "arpabetMappingVersion", "sourceComparisonPolicyVersion", "automaticSelectionPolicyVersion", "candidateValidationPolicyVersion"])
        for (_, entryValue) in try object(root["entries"]) {
            let entry = try object(entryValue)
            try exactKeys(entry, ["normalizedWord", "candidates"])
            for candidate in try array(entry, "candidates") {
                try exactKeys(try object(candidate), ["candidateID", "ipa", "sourceID", "authority", "validation", "automaticEligible"])
            }
        }
        try exactKeys(try object(root["report"]), ["overlaps", "disagreements", "incompatible"])
    }

    private static func exactKeys(_ object: [String: Any], _ keys: [String]) throws {
        guard Set(object.keys) == Set(keys) else { throw ValidationError.invalid("JSON shape") }
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw ValidationError.invalid("JSON object") }
        return object
    }

    private static func array(_ object: [String: Any], _ key: String) throws -> [Any] {
        guard let value = object[key] as? [Any] else { throw ValidationError.invalid("JSON array") }
        return value
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func isNormalizedWord(_ value: String) -> Bool {
        value.range(of: "^[a-z]+(?:['-][a-z]+)*$", options: .regularExpression) != nil
    }

    private static func isBounded(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
    }

    private static func isTimestamp(_ value: String) -> Bool {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", options: .regularExpression) != nil else { return false }
        return ISO8601DateFormatter().date(from: value) != nil
    }
}

/// Rejects duplicate JSON object members before Foundation's dictionary bridge
/// can silently collapse them. JSONSerialization supplies full JSON syntax and
/// Unicode validation; this pass supplies duplicate-member detection at every
/// nested object boundary.
nonisolated private enum StrictAuditPackJSON {
    static func object(from data: Data) throws -> [String: Any] {
        var scanner = Scanner(data: data)
        try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == data.endIndex,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
        return object
    }

    private struct Scanner {
        let data: Data
        var index: Data.Index

        init(data: Data) { self.data = data; index = data.startIndex }

        mutating func parseValue(depth: Int) throws {
            guard depth <= 64 else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON depth") }
            skipWhitespace()
            guard let byte = peek() else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
            if byte == 0x7B { try parseObject(depth: depth + 1) }
            else if byte == 0x5B { try parseArray(depth: depth + 1) }
            else if byte == 0x22 { _ = try parseString() }
            else { try parseScalar() }
        }

        mutating func parseObject(depth: Int) throws {
            advance()
            skipWhitespace()
            if consume(0x7D) { return }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else { throw EnglishPronunciationAuditPack.ValidationError.invalid("duplicate JSON key") }
                skipWhitespace()
                guard consume(0x3A) else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
            }
        }

        mutating func parseArray(depth: Int) throws {
            advance()
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
            }
        }

        mutating func parseString() throws -> String {
            guard consume(0x22) else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
            let start = index
            var escaped = false
            while let byte = peek() {
                advance()
                if escaped { escaped = false; continue }
                if byte == 0x5C { escaped = true; continue }
                if byte == 0x22 {
                    let end = data.index(before: index)
                    let bytes = data[start..<end]
                    let quoted = Data([0x22]) + bytes + Data([0x22])
                    guard let string = try JSONSerialization.jsonObject(
                        with: quoted, options: .fragmentsAllowed) as? String else {
                        throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON string")
                    }
                    return string
                }
            }
            throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON string")
        }

        mutating func parseScalar() throws {
            let start = index
            while let byte = peek(), ![0x2C, 0x5D, 0x7D, 0x20, 0x0A, 0x0D, 0x09].contains(byte) { advance() }
            guard index > start else { throw EnglishPronunciationAuditPack.ValidationError.invalid("JSON") }
        }

        mutating func skipWhitespace() { while let byte = peek(), [0x20, 0x0A, 0x0D, 0x09].contains(byte) { advance() } }
        func peek() -> UInt8? { index < data.endIndex ? data[index] : nil }
        mutating func advance() { index = data.index(after: index) }
        mutating func consume(_ byte: UInt8) -> Bool { guard peek() == byte else { return false }; advance(); return true }
    }
}
