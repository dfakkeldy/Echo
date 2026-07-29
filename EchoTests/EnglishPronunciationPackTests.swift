// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct EnglishPronunciationPackTests {
    private static let validPackJSON = #"""
    {"candidateCount":3,"dialect":"en-US","entries":{"example":[{"automaticWithoutContext":true,"candidateID":"cmudict.example.63ea23914424","frequencyBand":"unknown","ipa":"ɪɡzˈæmpəl","kind":"explicit","lexicalClass":null,"senseLabel":null,"sourceID":"cmudict","sourceTier":"supplemental","validationStatus":"validated-automatic"}],"record":[{"automaticWithoutContext":false,"candidateID":"cmudict.record.c47663dfd738","frequencyBand":"unknown","ipa":"ɹɪkˈɔɹd","kind":"explicit","lexicalClass":null,"senseLabel":null,"sourceID":"cmudict","sourceTier":"supplemental","validationStatus":"report-only-missing-sense-label"},{"automaticWithoutContext":false,"candidateID":"cmudict.record.c88be179c4c3","frequencyBand":"unknown","ipa":"ɹˈɛkɚd","kind":"explicit","lexicalClass":null,"senseLabel":null,"sourceID":"cmudict","sourceTier":"supplemental","validationStatus":"report-only-missing-sense-label"}]},"entryCount":2,"generationTimestamp":"2026-07-29T00:00:00Z","generatorVersion":"echo-pronunciation-pack-generator-v2","kokoroVocabularyVersion":"sha256:f94ae5cec55f4459480fa6c9523c5bf0debb7ac69360bdd0995d88f88fbfc2bf","licenses":[{"licenseID":"CMUdict-BSD-style","licensePath":"ThirdParty/CMUdict/LICENSE","sourceID":"cmudict"}],"normalizedDataSHA256":"sha256:9a21d3ed0f0d6d7ddbb6599fed76fd20eb3e9fa218b5cd7384768b7ea385fc47","packVersion":"sha256:c586761baa04123e34b201faf840657b99e247c2370800ccfd8ba7d3f681586d","report":{"ambiguous":1,"existingGold":0,"existingSilver":0,"imported":2,"incompatible":0},"requiredAcknowledgments":["CMUdict notice bundled from THIRD_PARTY_NOTICES.md"],"schemaVersion":1,"semanticIdentityPayload":{"dialect":"en-US","generatorBehavior":{"arpabetMappingVersion":"cmudict-arpabet-to-kokoro-v2","automaticSelectionPolicyVersion":"single-validated-compatible-candidate-v2","candidateValidationPolicyVersion":"source-candidate-validation-v1","generatorVersion":"echo-pronunciation-pack-generator-v2","normalizationPolicyVersion":"english-key-normalization-v1","sourcePrecedencePolicyVersion":"gold-silver-exclusion-v1"},"identitySchemaVersion":1,"kokoroVocabularyVersion":"sha256:f94ae5cec55f4459480fa6c9523c5bf0debb7ac69360bdd0995d88f88fbfc2bf","normalizedDataSHA256":"sha256:9a21d3ed0f0d6d7ddbb6599fed76fd20eb3e9fa218b5cd7384768b7ea385fc47","sourceSnapshots":[{"sha256":"sha256:1111111111111111111111111111111111111111111111111111111111111111","snapshotID":"cmudict@test","sourceID":"cmudict"},{"sha256":"sha256:2222222222222222222222222222222222222222222222222222222222222222","snapshotID":"gold@test","sourceID":"echo-us-gold"},{"sha256":"sha256:3333333333333333333333333333333333333333333333333333333333333333","snapshotID":"silver@test","sourceID":"echo-us-silver"}]},"sources":[{"role":"supplemental-candidates","sha256":"sha256:1111111111111111111111111111111111111111111111111111111111111111","snapshotID":"cmudict@test","sourceID":"cmudict"},{"role":"exclusion-input","sha256":"sha256:2222222222222222222222222222222222222222222222222222222222222222","snapshotID":"gold@test","sourceID":"echo-us-gold"},{"role":"exclusion-input","sha256":"sha256:3333333333333333333333333333333333333333333333333333333333333333","snapshotID":"silver@test","sourceID":"echo-us-silver"}]}
    """#

    @Test func validGeneratedManifestLoadsAndAutomaticLookupIsClosed() throws {
        let pack = try EnglishPronunciationPack(data: Data(Self.validPackJSON.utf8))

        #expect(pack.schemaVersion == 1)
        #expect(pack.entryCount == 2)
        #expect(pack.candidateCount == 3)
        #expect(pack.generatorBehavior.generatorVersion == pack.generatorVersion)
        #expect(pack.automaticCandidate(for: "example")?.candidateID
            == "cmudict.example.63ea23914424")
        #expect(pack.automaticCandidate(for: "record") == nil)
        #expect(pack.automaticCandidate(for: "Example") == nil)
        #expect(pack.automaticCandidate(for: "missing") == nil)
    }

    @Test func bundledPackLoadsThroughNarrationResources() async {
        let pack = await EnglishPronunciationPack.bundledOrEmpty()

        #expect(pack.packVersion.hasPrefix("sha256:"))
        #expect(pack.packVersion != EnglishPronunciationPack.empty.packVersion)
        #expect(pack.entryCount > 0)
        #expect(pack.candidateCount >= pack.entryCount)
    }

    @Test func emptyPackIsDeterministicAndInert() {
        #expect(EnglishPronunciationPack.empty == EnglishPronunciationPack.empty)
        #expect(EnglishPronunciationPack.empty.packVersion == "unavailable-v1")
        #expect(EnglishPronunciationPack.empty.entryCount == 0)
        #expect(EnglishPronunciationPack.empty.candidateCount == 0)
        #expect(EnglishPronunciationPack.empty.automaticCandidate(for: "example") == nil)
    }

    @Test func bundledInvalidPackFallsBackToDeterministicEmptyValue() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data("not-json".utf8).write(
            to: temporaryDirectory.appendingPathComponent("us_pronunciation_pack.json"))

        let original = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"]
        setenv("ECHO_RESOURCE_DIR", temporaryDirectory.path, 1)
        defer {
            if let original {
                setenv("ECHO_RESOURCE_DIR", original, 1)
            } else {
                unsetenv("ECHO_RESOURCE_DIR")
            }
        }

        #expect(await EnglishPronunciationPack.bundledOrEmpty() == .empty)
    }

    @Test func missingOrMalformedIdentityFieldsAreRejected() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0.removeValue(forKey: "schemaVersion") }),
            ("generator", { $0["generatorVersion"] = "" }),
            ("entry count", { $0.removeValue(forKey: "entryCount") }),
            ("candidate count", { $0["candidateCount"] = -1 }),
            ("entries digest", { $0["normalizedDataSHA256"] = "not-a-sha" }),
            ("vocabulary", { $0["kokoroVocabularyVersion"] = "sha256:abc" }),
            ("sources", { $0["sources"] = [] }),
            ("source snapshot", { root in
                var sources = root["sources"] as! [[String: Any]]
                sources[0]["sha256"] = "sha256:abc"
                root["sources"] = sources
            }),
            ("licenses", { $0["licenses"] = [] }),
            ("license path", { root in
                var licenses = root["licenses"] as! [[String: Any]]
                licenses[0]["licensePath"] = "ThirdParty/CMUdict/MISSING"
                root["licenses"] = licenses
            }),
            ("acknowledgments", { $0["requiredAcknowledgments"] = [] }),
            ("blank acknowledgment", {
                $0["requiredAcknowledgments"] = [" \n "]
            }),
            ("semantic payload", { $0.removeValue(forKey: "semanticIdentityPayload") }),
            ("generator behavior", { root in
                var payload = root["semanticIdentityPayload"] as! [String: Any]
                var behavior = payload["generatorBehavior"] as! [String: Any]
                behavior.removeValue(forKey: "arpabetMappingVersion")
                payload["generatorBehavior"] = behavior
                root["semanticIdentityPayload"] = payload
            }),
            ("timestamp", { $0["generationTimestamp"] = "2026-07-29T00:00:00.1Z" }),
        ]

        for (label, mutate) in mutations {
            #expect(
                throws: (any Error).self,
                "Expected rejection for \(label)"
            ) {
                _ = try EnglishPronunciationPack(data: Self.mutated(mutate))
            }
        }
    }

    @Test func everyCandidateKeyIncludingExplicitNullsIsRequired() throws {
        for key in [
            "candidateID", "ipa", "lexicalClass", "senseLabel", "sourceID",
            "sourceTier", "kind", "automaticWithoutContext", "frequencyBand",
            "validationStatus",
        ] {
            #expect(throws: (any Error).self, "Expected rejection for missing \(key)") {
                _ = try EnglishPronunciationPack(
                    data: Self.mutated { root in
                        var entries = root["entries"] as! [String: Any]
                        var candidates = entries["example"] as! [[String: Any]]
                        candidates[0].removeValue(forKey: key)
                        entries["example"] = candidates
                        root["entries"] = entries
                    })
            }
        }
    }

    @Test func duplicateObjectMembersAreRejectedAtEveryRelevantDepth() throws {
        let duplicateMembers = [
            Self.replacingFirst(
                #"{"candidateCount":3"#,
                with: #"{"candidateCount":3,"candidateCount":3"#),
            Self.replacingFirst(
                #""entries":{"example":["#,
                with: #""entries":{"example":[],"example":["#),
            Self.replacingFirst(
                #""candidateID":"cmudict.example.63ea23914424""#,
                with: #""candidateID":"cmudict.example.63ea23914424","candidateID":"cmudict.example.63ea23914424""#),
            Self.replacingFirst(
                #""candidateID":"cmudict.example.63ea23914424""#,
                with: #""candidateID":"cmudict.example.63ea23914424","candidate\u0049D":"cmudict.example.63ea23914424""#),
            Self.replacingFirst(
                #""identitySchemaVersion":1"#,
                with: #""identitySchemaVersion":1,"identitySchemaVersion":1"#),
            Self.replacingFirst(
                #""report":{"ambiguous":1"#,
                with: #""report":{"ambiguous":1,"ambiguous":1"#),
        ]

        for data in duplicateMembers {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: data)
            }
        }
    }

    @Test func unknownMembersCannotEscapeCanonicalIdentity() throws {
        let unknownMembers = [
            Self.replacingFirst(
                #"{"candidateCount":3"#,
                with: #"{"candidateCount":3,"unknownManifestAuthority":true"#),
            Self.replacingFirst(
                #""candidateID":"cmudict.example.63ea23914424""#,
                with: #""candidateID":"cmudict.example.63ea23914424","unhashedCandidateAuthority":"quote\\\" slash\\\\ unicode\\uD83D\\uDE00 } ]""#),
            Self.replacingFirst(
                #""sources":[{"role":"supplemental-candidates""#,
                with: #""sources":[{"unknownSourceAuthority":"unhashed","role":"supplemental-candidates""#),
            Self.replacingFirst(
                #""licenses":[{"licenseID":"CMUdict-BSD-style""#,
                with: #""licenses":[{"unknownLicenseAuthority":"unhashed","licenseID":"CMUdict-BSD-style""#),
            Self.replacingFirst(
                #""semanticIdentityPayload":{"dialect":"en-US""#,
                with: #""semanticIdentityPayload":{"unknownIdentityAuthority":"unhashed","dialect":"en-US""#),
            Self.replacingFirst(
                #""generatorBehavior":{"arpabetMappingVersion""#,
                with: #""generatorBehavior":{"unknownPolicyAuthority":"unhashed","arpabetMappingVersion""#),
            Self.replacingFirst(
                #""sourceSnapshots":[{"sha256""#,
                with: #""sourceSnapshots":[{"unknownSnapshotAuthority":"unhashed","sha256""#),
            Self.replacingFirst(
                #""report":{"ambiguous":1"#,
                with: #""report":{"unknownReportField":0,"ambiguous":1"#),
        ]

        for data in unknownMembers {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: data)
            }
        }
    }

    @Test func malformedStringsAndNestingFailBeforeTypedDecoding() {
        let malformed = [
            Data(#"{"candidateCount":3,"broken":"unterminated}"#.utf8),
            Data(#"{"candidateCount":3,"broken":"bad\q"}"#.utf8),
            Data(#"{"candidateCount":3,"broken":"bad\uD800"}"#.utf8),
            Data(#"{"candidateCount":3,"broken":[1,2}}"#.utf8),
        ]

        for data in malformed {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: data)
            }
        }
    }

    @Test func structuralValidationAcceptsEscapesAndUnicodeInValues() throws {
        let escaped = try Self.rehashed { root in
            Self.mutateFirstRecordCandidate(in: &root) {
                $0["validationStatus"] = "validated-human-reviewed"
                $0["senseLabel"] = "noun \"quoted\" \\ solidus / 😀"
            }
        }

        _ = try EnglishPronunciationPack(data: escaped)
    }

    @Test func oversizedDataIsRejectedBeforeStructuralDecoding() {
        #expect(EnglishPronunciationPack.maximumPackByteCount == 32 * 1_024 * 1_024)
        let oversized = Data(
            count: EnglishPronunciationPack.maximumPackByteCount + 1)

        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationPack(data: oversized)
        }
    }

    @Test func oversizedBundledResourceFailsClosedFromFileMetadata() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let resourceURL = temporaryDirectory
            .appendingPathComponent("us_pronunciation_pack.json")
        try Data().write(to: resourceURL)
        let file = try FileHandle(forWritingTo: resourceURL)
        try file.truncate(
            atOffset: UInt64(EnglishPronunciationPack.maximumPackByteCount + 1))
        try file.close()

        let original = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"]
        setenv("ECHO_RESOURCE_DIR", temporaryDirectory.path, 1)
        defer {
            if let original {
                setenv("ECHO_RESOURCE_DIR", original, 1)
            } else {
                unsetenv("ECHO_RESOURCE_DIR")
            }
        }

        #expect(await EnglishPronunciationPack.bundledOrEmpty() == .empty)
    }

    @Test func duplicateCandidateIDAndUnresolvedSourceAreRejected() throws {
        let duplicateID = try Self.mutated { root in
            var entries = root["entries"] as! [String: Any]
            var records = entries["record"] as! [[String: Any]]
            records[1]["candidateID"] = records[0]["candidateID"]
            entries["record"] = records
            root["entries"] = entries
        }
        let unresolvedSource = try Self.mutated { root in
            var entries = root["entries"] as! [String: Any]
            var records = entries["example"] as! [[String: Any]]
            records[0]["sourceID"] = "unknown-source"
            entries["example"] = records
            root["entries"] = entries
        }

        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationPack(data: duplicateID)
        }
        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationPack(data: unresolvedSource)
        }
    }

    @Test func candidateStatusInvariantsAreClosed() throws {
        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { root in
                Self.mutateFirstCandidate(in: &root) {
                    $0["automaticWithoutContext"] = false
                }
            },
            { root in
                Self.mutateFirstRecordCandidate(in: &root) {
                    $0["automaticWithoutContext"] = true
                }
            },
            { root in
                Self.mutateFirstRecordCandidate(in: &root) {
                    $0["senseLabel"] = "noun"
                }
            },
            { root in
                Self.mutateFirstRecordCandidate(in: &root) {
                    $0["validationStatus"] = "validated-human-reviewed"
                    $0["senseLabel"] = ""
                }
            },
            { root in
                Self.mutateFirstRecordCandidate(in: &root) {
                    $0["validationStatus"] = "validated-human-reviewed"
                    $0["senseLabel"] = "noun"
                    $0["automaticWithoutContext"] = true
                }
            },
        ]

        for mutate in invalidMutations {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: Self.mutated(mutate))
            }
        }
    }

    @Test func reportOnlyStatusRequiresGenuineAmbiguity() throws {
        let singletonReportOnly = try Self.rehashed { root in
            Self.mutateFirstCandidate(in: &root) {
                $0["validationStatus"] = "report-only-missing-sense-label"
                $0["automaticWithoutContext"] = false
            }
        }

        #expect(throws: (any Error).self) {
            _ = try EnglishPronunciationPack(data: singletonReportOnly)
        }
    }

    @Test func exactCMUdictAttributionIsRequiredOutsidePackIdentity() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { root in
                var licenses = root["licenses"] as! [[String: Any]]
                licenses[0]["licenseID"] = "not-the-cmudict-license"
                root["licenses"] = licenses
            },
            {
                $0["requiredAcknowledgments"] = [
                    "not a CMUdict acknowledgment",
                ]
            },
        ]

        for mutate in mutations {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: Self.mutated(mutate))
            }
        }
    }

    @Test func staleHashesCountsAndSemanticIdentityAreRejected() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["entryCount"] = 3 },
            { $0["candidateCount"] = 4 },
            { $0["packVersion"] = "sha256:" + String(repeating: "f", count: 64) },
            { root in
                Self.mutateFirstCandidate(in: &root) { $0["ipa"] = "changed" }
            },
            { root in
                var sources = root["sources"] as! [[String: Any]]
                sources.swapAt(0, 1)
                root["sources"] = sources
            },
            { root in
                var sources = root["sources"] as! [[String: Any]]
                sources[1]["sourceID"] = sources[0]["sourceID"]
                root["sources"] = sources
            },
            { root in
                var sources = root["sources"] as! [[String: Any]]
                sources[0]["snapshotID"] = "cmudict@changed"
                root["sources"] = sources
            },
        ]

        for mutate in mutations {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: Self.mutated(mutate))
            }
        }
    }

    @Test func semanticMutationsRequireANewPackVersion() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { root in
                var payload = root["semanticIdentityPayload"] as! [String: Any]
                var behavior = payload["generatorBehavior"] as! [String: Any]
                behavior["generatorVersion"] = "echo-pronunciation-pack-generator-v3"
                payload["generatorBehavior"] = behavior
                root["semanticIdentityPayload"] = payload
                root["generatorVersion"] = "echo-pronunciation-pack-generator-v3"
            },
            { root in
                let changed = "sha256:" + String(repeating: "e", count: 64)
                var payload = root["semanticIdentityPayload"] as! [String: Any]
                payload["kokoroVocabularyVersion"] = changed
                root["semanticIdentityPayload"] = payload
                root["kokoroVocabularyVersion"] = changed
            },
            { root in
                var sources = root["sources"] as! [[String: Any]]
                var payload = root["semanticIdentityPayload"] as! [String: Any]
                var snapshots = payload["sourceSnapshots"] as! [[String: Any]]
                sources[0]["snapshotID"] = "cmudict@changed"
                snapshots[0]["snapshotID"] = "cmudict@changed"
                root["sources"] = sources
                payload["sourceSnapshots"] = snapshots
                root["semanticIdentityPayload"] = payload
            },
        ]

        for mutate in mutations {
            #expect(throws: (any Error).self) {
                _ = try EnglishPronunciationPack(data: Self.mutated(mutate))
            }
        }
    }

    @Test func generationTimestampIsAuditOnly() throws {
        let first = try EnglishPronunciationPack(data: Data(Self.validPackJSON.utf8))
        let second = try EnglishPronunciationPack(
            data: Self.mutated {
                $0["generationTimestamp"] = "2026-07-30T12:34:56Z"
            })

        #expect(first.packVersion == second.packVersion)
        #expect(first.normalizedDataSHA256 == second.normalizedDataSHA256)
        #expect(first.generatorBehavior == second.generatorBehavior)
        #expect(first.sources == second.sources)
        #expect(first.generationTimestamp != second.generationTimestamp)
    }

    private static func mutated(
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(validPackJSON.utf8))
                as? [String: Any])
        mutate(&root)
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func rehashed(
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(validPackJSON.utf8))
                as? [String: Any])
        mutate(&root)

        let entries = try #require(root["entries"])
        let entriesData = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let entriesIdentity = "sha256:" + SHA256.hash(data: entriesData)
            .map { String(format: "%02x", $0) }
            .joined()
        root["normalizedDataSHA256"] = entriesIdentity

        var payload = try #require(
            root["semanticIdentityPayload"] as? [String: Any])
        payload["normalizedDataSHA256"] = entriesIdentity
        root["semanticIdentityPayload"] = payload
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes])
        root["packVersion"] = "sha256:" + SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func replacingFirst(
        _ target: String,
        with replacement: String
    ) -> Data {
        guard let range = validPackJSON.range(of: target) else {
            Issue.record("Missing fixture marker: \(target)")
            return Data()
        }
        var result = validPackJSON
        result.replaceSubrange(range, with: replacement)
        return Data(result.utf8)
    }

    private static func mutateFirstCandidate(
        in root: inout [String: Any],
        _ mutate: (inout [String: Any]) -> Void
    ) {
        var entries = root["entries"] as! [String: Any]
        var candidates = entries["example"] as! [[String: Any]]
        mutate(&candidates[0])
        entries["example"] = candidates
        root["entries"] = entries
    }

    private static func mutateFirstRecordCandidate(
        in root: inout [String: Any],
        _ mutate: (inout [String: Any]) -> Void
    ) {
        var entries = root["entries"] as! [String: Any]
        var candidates = entries["record"] as! [[String: Any]]
        mutate(&candidates[0])
        entries["record"] = candidates
        root["entries"] = entries
    }
}
