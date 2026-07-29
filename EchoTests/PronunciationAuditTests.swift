// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAuditTests {
    private static let schemaThreeManifestJSON = #"""
        {
          "schemaVersion": 3,
          "renderVersion": 15,
          "voice": "af_heart",
          "chapterVoices": {},
          "coverage": "complete",
          "legacyChapterIndexes": [],
          "audiobookFileName": "book.m4b",
          "audiobookSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "listeningReelFileName": null,
          "listeningReelSHA256": null,
          "watchCounts": {},
          "decisions": [],
          "diagnostics": []
        }
        """#

    private func decision(
        word: String,
        ruleID: String,
        chapterIndex: Int,
        range: PronunciationAuditDecision.AudioRange? = .init(start: 1, end: 1.4)
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "s\(chapterIndex)-b0",
            wordStart: 2,
            wordEnd: 2,
            normalizedWord: word,
            sourceWord: word,
            sourceContext: "The result was \(word) in this bounded context",
            selectedIPA: "ipa-\(word)",
            kokoroTokenIDs: [11, 22, 33],
            source: .monitoredLexicon,
            ruleID: ruleID,
            rationale: "A stable test rationale for \(word).",
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: range,
            bookRelativeAudioRange: range.map {
                .init(
                    start: Double(chapterIndex * 10) + $0.start,
                    end: Double(chapterIndex * 10) + $0.end)
            },
            timingPrecision: range == nil ? nil : .exactSynthesisWord)
    }

    private func diagnostic(
        chapterIndex: Int = 1
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .spokenSurfaceMismatch,
            blockID: "s\(chapterIndex)-b0",
            chunkIndex: 0,
            chapterIndex: chapterIndex,
            expectedDisplayText: "verified filesystem",
            reconstructedSpokenSurface: "verified file system",
            fallbackHits: [])
    }

    private func contextualEvidence(
        availability: ContextualModelAvailability = .available,
        failure: ContextualModelFailure? = nil
    ) -> ContextualPronunciationEvidence {
        ContextualPronunciationEvidence(
            occurrenceID: "occurrence-record",
            familyID: "record",
            candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
            submittedCandidateIDs: ["record.noun", "record.verb"],
            deterministicCandidateID: "record.noun",
            deterministicRuleID: "record.noun.fixture",
            deterministicStrength: .definitive,
            modelCandidateID: availability == .available && failure == nil
                ? "record.verb"
                : nil,
            modelAbstained: false,
            modelAvailability: availability,
            modelFailure: failure,
            familyState: .shadow,
            acceptanceReason: failure != nil
                ? .shadowModelFailure
                : availability == .available
                    ? .shadowObserved
                    : .shadowModelUnavailable,
            promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
            platform: "test",
            osBuild: "test-build",
            qualifiedRuntimeFamilyID: "test-runtime",
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: availability != .available || failure != nil)
    }

    private func contextualDecision(
        evidence: ContextualPronunciationEvidence?
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "Please record this bounded fixture",
            selectedIPA: "ɹəkˈɔɹd",
            kokoroTokenIDs: [1, 2, 3],
            source: .contextualHomograph,
            ruleID: "homograph.record.verb",
            rationale: "Deterministic production decision.",
            contextualEvidence: evidence,
            chapterIndex: 0,
            chapterRelativeAudioRange: .init(start: 1, end: 1.2),
            bookRelativeAudioRange: .init(start: 1, end: 1.2),
            timingPrecision: .exactSynthesisWord)
    }

    @Test func englishKeyNormalizationCanonicalizesInternalCurlyApostrophe() {
        #expect(PronunciationAuditContext.normalizedWord("aujourd'hui") == "aujourd'hui")
        #expect(PronunciationAuditContext.normalizedWord("aujourd’hui") == "aujourd'hui")
        #expect(PronunciationAuditContext.normalizedWord("Aujourd’hui") == "aujourd'hui")
    }

    @Test func manifestPreservesStableEvidenceAndCountsEveryWatchedWord() {
        let second = decision(
            word: "filesystem", ruleID: "override.builtin.filesystem", chapterIndex: 2)
        let first = decision(word: "verified", ruleID: "g2p.lexicon.verified", chapterIndex: 0)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/private/books/question-machine.m4b"),
            reelURL: URL(fileURLWithPath: "/private/books/question-machine.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: String(repeating: "b", count: 64),
            watchWords: ["verified", "startable", "filesystem"],
            decisions: [first, second],
            diagnostics: [])

        #expect(manifest.schemaVersion == 4)
        #expect(manifest.renderVersion == 11)
        #expect(manifest.voice == "af_heart")
        #expect(manifest.coverage == .complete)
        #expect(manifest.legacyChapterIndexes.isEmpty)
        #expect(manifest.audiobookFileName == "question-machine.m4b")
        #expect(manifest.audiobookSHA256 == String(repeating: "a", count: 64))
        #expect(manifest.listeningReelFileName == "question-machine.pronunciation-reel.m4b")
        #expect(manifest.listeningReelSHA256 == String(repeating: "b", count: 64))
        #expect(manifest.watchCounts == ["filesystem": 1, "startable": 0, "verified": 1])
        #expect(manifest.decisions == [first, second])
        #expect(manifest.decisions[0].chapterRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].bookRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].kokoroTokenIDs == [11, 22, 33])
        #expect(manifest.diagnostics.isEmpty)
    }

    @Test func mixedVoiceManifestPreservesCompleteChapterProvenance() throws {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("mixed"),
            chapterVoices: [0: VoiceID("af_heart"), 4: VoiceID("bf_emma")],
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-sampler.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(manifest.voice == "mixed")
        #expect(manifest.chapterVoices == ["0": "af_heart", "4": "bf_emma"])
        #expect(throws: Never.self) { _ = try manifest.encoded() }
    }

    @Test func manifestRejectsMalformedChapterVoiceProvenance() throws {
        let valid = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("mixed"),
            chapterVoices: [0: VoiceID("af_heart"), 4: VoiceID("bf_emma")],
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-sampler.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let validObject = try #require(
            JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any])

        for malformedVoices in [
            ["-1": "af_heart", "4": "bf_emma"],
            ["01": "af_heart", "4": "bf_emma"],
            ["chapter-one": "af_heart", "4": "bf_emma"],
            ["0": "not_a_voice", "4": "bf_emma"],
        ] {
            var object = validObject
            object["chapterVoices"] = malformedVoices
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: data)
            }
        }
    }

    @Test func manifestCountsDecisionsOutsideConfiguredWatchVocabulary() {
        let mara = decision(word: "mara", ruleID: "g2p.lexicon.mara", chapterIndex: 0)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 13,
            voice: VoiceID("am_michael"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [mara],
            diagnostics: [])

        #expect(manifest.watchCounts == ["mara": 1, "verified": 0])
    }

    @Test func manifestDistinguishesLegacyCaptureFromEvidenceDiagnostics() {
        let evidenceDiagnostic = diagnostic()
        let incompleteEvidence = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])
        let legacy = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteLegacyCapture,
            legacyChapterIndexes: [1, 7],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])

        #expect(incompleteEvidence.coverage == .incompleteEvidence)
        #expect(incompleteEvidence.diagnostics == [evidenceDiagnostic])
        #expect(legacy.coverage == .incompleteLegacyCapture)
        #expect(legacy.legacyChapterIndexes == [1, 7])
    }

    @Test func contextualEvidenceSurvivesMaterializationTimingAndSchemaFourJSON() throws {
        let evidence = contextualEvidence()
        let seed = PronunciationDecisionSeed(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "Please record this bounded fixture",
            selectedIPA: "ɹəkˈɔɹd",
            source: .contextualHomograph,
            ruleID: "homograph.record.verb",
            rationale: "Deterministic production decision.",
            contextualEvidence: evidence)
        let decision = seed.materialized(
            selectedIPA: "ɹəkˈɔɹd",
            kokoroTokenIDs: [1, 2, 3]
        )
        .attachingRenderTiming(
            chapterIndex: 2,
            chapterRelativeAudioRange: .init(start: 1, end: 1.2),
            timingPrecision: .exactSynthesisWord
        )
        .attachingBookTiming(chapterIndex: 2, chapterOffset: 10)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [decision],
            diagnostics: [])
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded())

        #expect(decoded.coverage == .complete)
        #expect(decoded.decisions.first?.contextualEvidence == evidence)
        #expect(decoded.decisions.first?.selectedIPA == "ɹəkˈɔɹd")
        #expect(
            decoded.decisions.first?.bookRelativeAudioRange
                == .init(start: 11, end: 11.2))
    }

    @Test func unavailableEnvelopeIsCompleteButMissingCurrentEvidenceIsIncomplete() {
        let unavailable = contextualDecision(
            evidence: contextualEvidence(availability: .deviceNotEligible))
        let missing = contextualDecision(evidence: nil)
        func manifest(for decision: PronunciationAuditDecision) -> PronunciationAuditManifest {
            PronunciationAuditManifest.make(
                renderVersion: NarrationFileNaming.renderVersion,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [decision],
                diagnostics: [])
        }

        #expect(manifest(for: unavailable).coverage == .complete)
        #expect(manifest(for: missing).coverage == .incompleteEvidence)
    }

    @Test func legacyChapterListWinsOverOtherwiseCompleteOrDiagnosticCoverage() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteEvidence,
            legacyChapterIndexes: [9, 2, 9],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [diagnostic()])

        #expect(manifest.coverage == .incompleteLegacyCapture)
        #expect(manifest.legacyChapterIndexes == [2, 9])
    }

    @Test func zeroDecisionManifestStillCarriesAllZeroWatchCountsAndNoReel() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem", "verified"],
            decisions: [],
            diagnostics: [])

        #expect(manifest.decisions.isEmpty)
        #expect(manifest.watchCounts == ["filesystem": 0, "verified": 0])
        #expect(manifest.listeningReelFileName == nil)
        #expect(manifest.coverage == .complete)
    }

    @Test func manifestEncodingIsPrettySortedAndAtomicallyReplacesExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("book.pronunciation-audit.json")

        let oldManifest = PronunciationAuditManifest.make(
            renderVersion: 10,
            voice: VoiceID("old_voice"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "c", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [decision(word: "verified", ruleID: "old", chapterIndex: 0)],
            diagnostics: [])
        let newManifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "d", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem"],
            decisions: [],
            diagnostics: [])

        try oldManifest.write(to: destination)
        try newManifest.write(to: destination)

        let data = try Data(contentsOf: destination)
        let text = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(PronunciationAuditManifest.self, from: data)
        let audiobookKey = try #require(text.range(of: "\"audiobookFileName\""))
        let coverageKey = try #require(text.range(of: "\"coverage\""))
        let schemaKey = try #require(text.range(of: "\"schemaVersion\""))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)

        #expect(text.hasPrefix("{\n"))
        #expect(audiobookKey.lowerBound < coverageKey.lowerBound)
        #expect(coverageKey.lowerBound < schemaKey.lowerBound)
        #expect(decoded == newManifest)
        #expect(siblings.map(\.lastPathComponent) == [destination.lastPathComponent])
        #expect(!text.contains(tmp.path))
    }

    @Test func manifestEncodingRejectsMalformedOrUnpairedArtifactHashes() {
        let malformed = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: "NOT-A-SHA256",
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let unpaired = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: URL(fileURLWithPath: "/tmp/book.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(throws: Error.self) { _ = try malformed.encoded() }
        #expect(throws: Error.self) { _ = try unpaired.encoded() }
    }

    @Test func schemaThreeAuditDecodesAsIncompleteEvidence() throws {
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: Data(Self.schemaThreeManifestJSON.utf8))
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: decoded.encoded())
                as? [String: Any])

        #expect(decoded.schemaVersion == 3)
        #expect(decoded.coverage == .incompleteEvidence)
        #expect(reencoded["schemaVersion"] as? Int == 4)
        #expect(reencoded["coverage"] as? String == "incompleteEvidence")
    }

    @Test func schemaThreeLegacyLimitationRemainsStronger() throws {
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.schemaThreeManifestJSON.utf8)) as? [String: Any])
        root["coverage"] = "incompleteLegacyCapture"
        root["legacyChapterIndexes"] = [2]

        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: root))

        #expect(decoded.schemaVersion == 3)
        #expect(decoded.coverage == .incompleteLegacyCapture)
        #expect(decoded.legacyChapterIndexes == [2])
    }

    @Test func unsupportedAuditSchemasAreRejectedDuringDecoding() throws {
        for schemaVersion in [2, 5] {
            var root = try #require(
                JSONSerialization.jsonObject(
                    with: Data(Self.schemaThreeManifestJSON.utf8)) as? [String: Any])
            root["schemaVersion"] = schemaVersion

            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    @Test func derivedProvenanceSurvivesMaterializationTimingAndJSONRoundTrip() throws {
        let seed = PronunciationDecisionSeed(
            blockID: "s0-b0",
            wordStart: 3,
            wordEnd: 3,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "The widget is startable now",
            selectedIPA: "stˈɑɹtəbəl",
            source: .derivedMorphology,
            ruleID: "universal.morphology",
            rationale: "One validated base and one versioned rule.",
            candidateID: "morphology.startable.0123456789ab",
            candidatePackVersion: "morphology-v1:sha256:"
                + String(repeating: "a", count: 64),
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1")

        let materialized = seed.materialized(
            selectedIPA: "stˈɑɹtəbəl",
            kokoroTokenIDs: [10, 20, 30])
        let rendered = materialized.attachingRenderTiming(
            chapterIndex: 4,
            chapterRelativeAudioRange: .init(start: 2, end: 2.5),
            timingPrecision: .exactSynthesisWord)
        let booked = rendered.attachingBookTiming(
            chapterIndex: 4,
            chapterOffset: 100)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [booked],
            diagnostics: [])
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded())
        let decision = try #require(decoded.decisions.first)

        #expect(decoded.schemaVersion == 4)
        #expect(decision.candidateID == "morphology.startable.0123456789ab")
        #expect(
            decision.candidatePackVersion
                == "morphology-v1:sha256:" + String(repeating: "a", count: 64))
        #expect(decision.derivationBase == "start")
        #expect(decision.derivationRuleID == "morphology.able.exact-base.v1")
        #expect(
            decision.chapterRelativeAudioRange
                == PronunciationAuditDecision.AudioRange(start: 2, end: 2.5))
        #expect(
            decision.bookRelativeAudioRange
                == PronunciationAuditDecision.AudioRange(start: 102, end: 102.5))
    }

    @Test func supplementalProvenanceSurvivesWithoutMorphologyFields() throws {
        let decision = PronunciationDecisionSeed(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "example",
            sourceWord: "Example",
            sourceContext: "Example",
            selectedIPA: "ɪɡzˈæmpəl",
            source: .supplementalLexicon,
            ruleID: "universal.supplemental",
            rationale: "One validated supplemental candidate.",
            candidateID: "cmudict.example.63ea23914424",
            candidatePackVersion: "sha256:" + String(repeating: "b", count: 64)
        )
        .materialized(
            selectedIPA: "ɪɡzˈæmpəl",
            kokoroTokenIDs: [1, 2, 3])

        #expect(decision.candidateID == "cmudict.example.63ea23914424")
        #expect(
            decision.candidatePackVersion
                == "sha256:" + String(repeating: "b", count: 64))
        #expect(decision.derivationBase == nil)
        #expect(decision.derivationRuleID == nil)
    }

    @Test func universalDecisionsRejectIncompleteProvenanceCombinations() throws {
        let validSupplemental = PronunciationAuditDecision(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "example",
            sourceWord: "example",
            sourceContext: "example",
            selectedIPA: "ipa",
            kokoroTokenIDs: [1],
            source: .supplementalLexicon,
            ruleID: "universal.supplemental",
            rationale: "fixture",
            candidateID: "cmudict.example.fixture",
            candidatePackVersion: "sha256:" + String(repeating: "c", count: 64))
        let validDerived = PronunciationAuditDecision(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "startable",
            selectedIPA: "ipa",
            kokoroTokenIDs: [1],
            source: .derivedMorphology,
            ruleID: "universal.morphology",
            rationale: "fixture",
            candidateID: "morphology.startable.fixture",
            candidatePackVersion: "morphology-v1:sha256:"
                + String(repeating: "d", count: 64),
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1")

        let invalid = [
            replacingProvenance(validSupplemental, candidateID: .some(nil)),
            replacingProvenance(validSupplemental, candidatePackVersion: .some(nil)),
            replacingProvenance(validSupplemental, derivationBase: "example"),
            replacingProvenance(validDerived, candidateID: ""),
            replacingProvenance(validDerived, candidatePackVersion: ""),
            replacingProvenance(validDerived, derivationBase: ""),
            replacingProvenance(validDerived, derivationRuleID: ""),
        ]

        for decision in invalid {
            let manifest = PronunciationAuditManifest.make(
                renderVersion: 15,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [decision],
                diagnostics: [])
            #expect(throws: (any Error).self) { _ = try manifest.encoded() }
            let rawSchemaFour = try JSONEncoder().encode(manifest)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: rawSchemaFour)
            }
        }
    }

    private func replacingProvenance(
        _ decision: PronunciationAuditDecision,
        candidateID: String?? = nil,
        candidatePackVersion: String?? = nil,
        derivationBase: String?? = nil,
        derivationRuleID: String?? = nil
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: decision.blockID,
            wordStart: decision.wordStart,
            wordEnd: decision.wordEnd,
            normalizedWord: decision.normalizedWord,
            sourceWord: decision.sourceWord,
            sourceContext: decision.sourceContext,
            selectedIPA: decision.selectedIPA,
            kokoroTokenIDs: decision.kokoroTokenIDs,
            source: decision.source,
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            candidateID: candidateID ?? decision.candidateID,
            candidatePackVersion: candidatePackVersion ?? decision.candidatePackVersion,
            derivationBase: derivationBase ?? decision.derivationBase,
            derivationRuleID: derivationRuleID ?? decision.derivationRuleID)
    }
}
