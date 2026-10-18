// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct EnglishPronunciationAuditPackTests {
    @Test func bundledAuditPackLoadsOnlyShadowCandidates() throws {
        let url = try #require(NarrationResources.url(
            forResource: "us_pronunciation_audit_pack", withExtension: "json"))
        let pack = try EnglishPronunciationAuditPack(data: Data(contentsOf: url))

        #expect(pack.auditPackVersion.hasPrefix("sha256:"))
        #expect(pack.auditPackVersion != EnglishPronunciationAuditPack.empty.auditPackVersion)
        #expect(pack.entryCount > 0)
        #expect(pack.candidateCount >= pack.entryCount)
        #expect(pack.alternatives(for: "record").allSatisfy {
            $0.authority == "uncertain"
                && $0.validation == "shadow"
                && !$0.automaticEligible
        })
    }

    @Test func malformedAuditPackFailsClosed() {
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(data: Data("not-json".utf8))
        }
    }

    @Test func rehashedFixtureLoads() throws {
        _ = try EnglishPronunciationAuditPack(data: Self.fixtureData())
    }

    @Test func schemaDigestAndDuplicateJSONKeyFailuresAreClosed() throws {
        var wrongSchema = try Self.fixtureRoot()
        wrongSchema["schemaVersion"] = 2
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(data: try Self.data(wrongSchema))
        }

        var staleDigest = try Self.fixtureRoot()
        var entries = staleDigest["entries"] as! [String: Any]
        var entry = entries["record"] as! [String: Any]
        var candidates = entry["candidates"] as! [[String: Any]]
        candidates[0]["ipa"] = "ɹˈɛkɚd"
        entry["candidates"] = candidates
        entries["record"] = entry
        staleDigest["entries"] = entries
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(data: try Self.data(staleDigest))
        }

        let raw = try String(decoding: Self.fixtureData(), as: UTF8.self)
        let candidateID = try #require((try Self.recordCandidates()).first?["candidateID"] as? String)
        let field = "\"candidateID\":\"\(candidateID)\""
        let duplicate = Self.replacingFirst(
            raw,
            field,
            with: "\(field),\"candidateID\":\"duplicate\""
        )
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(data: Data(duplicate.utf8))
        }
    }

    @Test func candidateMetadataVocabularyAndAuditInvariantsFailClosed() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("candidate authority", { root in
                Self.mutateRecordCandidates(in: &root) { $0[0]["authority"] = "proven" }
            }),
            ("candidate source", { root in
                Self.mutateRecordCandidates(in: &root) { candidates in
                    candidates[0]["sourceID"] = "unknown-source"
                    candidates[0]["candidateID"] = Self.candidateID(
                        sourceID: "unknown-source", word: "record", ipa: candidates[0]["ipa"] as! String)
                }
            }),
            ("candidate vocabulary", { root in
                Self.mutateRecordCandidates(in: &root) { candidates in
                    candidates[0]["ipa"] = "❓"
                    candidates[0]["candidateID"] = Self.candidateID(
                        sourceID: candidates[0]["sourceID"] as! String, word: "record", ipa: "❓")
                }
            }),
            ("missing CMUdict", { root in
                Self.mutateRecordCandidates(in: &root) {
                    $0.removeAll { $0["sourceID"] as? String == "cmudict" }
                }
            }),
            ("missing comparison source", { root in
                Self.mutateRecordCandidates(in: &root) {
                    $0.removeAll { $0["sourceID"] as? String != "cmudict" }
                }
            }),
            ("no disagreement", { root in
                Self.mutateRecordCandidates(in: &root) { candidates in
                    let cmudict = candidates.first { $0["sourceID"] as? String == "cmudict" }!
                    var comparison = candidates.first { $0["sourceID"] as? String != "cmudict" }!
                    let cmudictIPA = cmudict["ipa"] as! String
                    let sourceID = comparison["sourceID"] as! String
                    comparison["ipa"] = cmudictIPA
                    comparison["candidateID"] = Self.candidateID(
                        sourceID: sourceID, word: "record", ipa: cmudictIPA)
                    candidates = [cmudict, comparison]
                }
            }),
            ("exact duplicate candidate", { root in
                Self.mutateRecordCandidates(in: &root) { candidates in
                    candidates.append(candidates[0])
                }
            }),
            ("mismatched candidate ID", { root in
                Self.mutateRecordCandidates(in: &root) {
                    $0[0]["candidateID"] = "cmudict.record.000000000000"
                }
            }),
        ]

        for (label, mutate) in mutations {
            #expect(throws: (any Error).self, "Expected rejection for \(label)") {
                _ = try EnglishPronunciationAuditPack(data: try Self.rehashedFixture(mutating: mutate))
            }
        }
    }

    @Test func oversizedAuditPackIsRejectedBeforeDecoding() {
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationAuditPack(
                data: Data(count: EnglishPronunciationAuditPack.maximumPackByteCount + 1))
        }
    }

    @Test func auditVersionCannotChangeProductionPolicySignature() async {
        let production = EnglishPronunciationPack.empty
        let before = production.productionPolicySignature
        let audit = await EnglishPronunciationAuditPack.bundledOrEmpty()
        let after = production.productionPolicySignature

        #expect(audit.auditPackVersion != "")
        #expect(after == before)
    }

    private static func fixtureRoot() throws -> [String: Any] {
        let url = try #require(NarrationResources.url(
            forResource: "us_pronunciation_audit_pack", withExtension: "json"))
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let entries = root["entries"] as! [String: Any]
        let record = try #require(entries["record"])
        root["entries"] = ["record": record]
        root["entryCount"] = 1
        root["candidateCount"] = ((record as! [String: Any])["candidates"] as! [[String: Any]]).count
        root["report"] = ["overlaps": 1, "disagreements": 1, "incompatible": 0]
        return try rehashed(root)
    }

    private static func recordCandidates() throws -> [[String: Any]] {
        let root = try fixtureRoot()
        return ((root["entries"] as! [String: Any])["record"] as! [String: Any])["candidates"] as! [[String: Any]]
    }

    private static func rehashedFixture(
        mutating mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try fixtureRoot()
        mutate(&root)
        return try data(try rehashed(root))
    }

    private static func mutateRecordCandidates(
        in root: inout [String: Any],
        _ mutate: (inout [[String: Any]]) -> Void
    ) {
        var entries = root["entries"] as! [String: Any]
        var record = entries["record"] as! [String: Any]
        var candidates = record["candidates"] as! [[String: Any]]
        mutate(&candidates)
        record["candidates"] = candidates
        entries["record"] = record
        root["entries"] = entries
        root["candidateCount"] = candidates.count
    }

    private static func rehashed(_ root: [String: Any]) throws -> [String: Any] {
        var rehashed = root
        let entries = rehashed["entries"]!
        let digest = sha256(try data(entries))
        rehashed["normalizedDataSHA256"] = digest
        var identity = rehashed["semanticIdentityPayload"] as! [String: Any]
        identity["normalizedDataSHA256"] = digest
        rehashed["semanticIdentityPayload"] = identity
        rehashed["auditPackVersion"] = sha256(try data(identity))
        return rehashed
    }

    private static func fixtureData() throws -> Data {
        try data(try fixtureRoot())
    }

    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func candidateID(sourceID: String, word: String, ipa: String) -> String {
        let digest = SHA256.hash(data: Data("\(sourceID)\0\(word)\0\(ipa)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(sourceID).\(word).\(digest.prefix(12))"
    }

    private static func replacingFirst(_ value: String, _ needle: String, with replacement: String) -> String {
        guard let range = value.range(of: needle) else {
            return value
        }
        return value.replacingCharacters(in: range, with: replacement)
    }
}
