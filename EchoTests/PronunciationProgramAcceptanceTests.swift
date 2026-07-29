// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite(.serialized) struct PronunciationProgramAcceptanceTests {
    private struct ContextualFixture: Decodable {
        let caseID: String
        let familyID: String
        let targetWord: String
        let labelStatus: String
        let labelA: String?
        let labelB: String?
        let adjudicated: String?
        let provenance: String
    }

    private struct NamedFixture: Decodable {
        let caseID: String
        let familyID: String
        let targetWord: String
        let shape: String
        let targetSentence: String
        let expectedCandidateID: String
        let expectedOutcome: String
    }

    private struct MorphologyFixture: Decodable {
        let caseID: String
        let word: String
        let expectedBase: String?
        let expectedRuleID: String?
        let expectedIPA: String?
        let automatic: Bool
    }

    private struct CanonicalCandidate: Codable {
        let candidateID: String
        let ipa: String
        let lexicalClass: String?
        let senseLabel: String?
        let sourceID: String
        let sourceTier: String
        let kind: String
        let automaticWithoutContext: Bool
        let frequencyBand: String
        let validationStatus: String

        private enum CodingKeys: String, CodingKey {
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
            try container.encode(
                automaticWithoutContext,
                forKey: .automaticWithoutContext)
            try container.encode(frequencyBand, forKey: .frequencyBand)
            try container.encode(validationStatus, forKey: .validationStatus)
        }
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixturesURL: URL {
        repositoryURL
            .appendingPathComponent("EchoTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Pronunciation")
    }

    private var packURL: URL {
        repositoryURL
            .appendingPathComponent("EchoCore")
            .appendingPathComponent("Services")
            .appendingPathComponent("Narration")
            .appendingPathComponent("PronunciationResources")
            .appendingPathComponent("us_pronunciation_pack.json")
    }

    private func jsonLines<T: Decodable>(
        _ type: T.Type,
        named name: String
    ) throws -> [T] {
        let data = try Data(
            contentsOf: fixturesURL.appendingPathComponent(name))
        return try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    private func block(id: String, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "synthetic-program-acceptance",
            spineHref: "fixture.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: "paragraph",
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
    }

    private func canonicalData(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func sha256Identity(_ data: Data) -> String {
        "sha256:"
            + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @Test func committedCorpusHasExactTruthfulWaitingCounts() throws {
        let contextual = try jsonLines(
            ContextualFixture.self,
            named: "contextual_family_candidates_v1.jsonl")
        let named = try jsonLines(
            NamedFixture.self,
            named: "named_regressions_v1.jsonl")
        let morphology = try jsonLines(
            MorphologyFixture.self,
            named: "morphology_v1.jsonl")
        let distribution = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixturesURL.appendingPathComponent(
                    "distribution_works_v1.json")))
        let research = try #require(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixturesURL.appendingPathComponent(
                        "candidate_source_research_v1.json")))
                as? [String: Any])

        #expect(contextual.count == 12)
        #expect(named.count == 36)
        #expect(morphology.count == 14)
        #expect((distribution as? [Any])?.count == 10)
        #expect((research["sources"] as? [Any])?.count == 5)
        #expect(contextual.allSatisfy { $0.labelStatus == "provisional" })
        #expect(contextual.allSatisfy { $0.labelA == nil && $0.labelB == nil })
        #expect(contextual.allSatisfy { $0.adjudicated == nil })
        #expect(Set(contextual.map(\.provenance)) == ["synthetic"])

        let qualifying = contextual.filter { $0.labelStatus == "human-labelled" }
        #expect(qualifying.isEmpty)
        let familyCounts = Dictionary(
            uniqueKeysWithValues: ["content", "live", "read", "record"].map { family in
                (family, qualifying.filter { $0.familyID == family }.count)
            })
        #expect(familyCounts.values.allSatisfy { $0 == 0 })
        #expect(
            Dictionary(
                uniqueKeysWithValues: familyCounts.keys.map {
                    ($0, 200 - familyCounts[$0, default: 0])
                })
                == ["content": 200, "live": 200, "read": 200, "record": 200])
        let missingSenseCounts = [
            "content.material": 50,
            "content.satisfied": 50,
            "live.adjective": 50,
            "live.verb": 50,
            "lives.noun": 50,
            "lives.verb": 50,
            "read.past": 50,
            "read.present": 50,
            "record.noun": 50,
            "record.verb": 50,
        ]
        #expect(missingSenseCounts.values.allSatisfy { $0 == 50 })
    }

    @Test func everyNamedRegressionMatchesTheClosedFamilyAndAnalyzerContract() throws {
        let rows = try jsonLines(
            NamedFixture.self,
            named: "named_regressions_v1.jsonl")

        for row in rows {
            let family = try #require(
                ContextualPronunciationFamilies.family(
                    for: row.targetWord.lowercased()))
            #expect(family.familyID == row.familyID, Comment(rawValue: row.caseID))
            #expect(
                family.candidates.map(\.candidateID).contains(
                    row.expectedCandidateID),
                Comment(rawValue: row.caseID))

            let displayText = MisakiPronunciationMarkup.displayText(
                from: row.targetSentence)
            let displayWords =
                WordTokenizer.words(in: displayText).map(String.init)
            let targetWordStart = displayWords.firstIndex {
                PronunciationAuditContext.normalizedWord($0)
                    == row.targetWord.lowercased()
            }
            let discovered = ContextualPronunciationDiscovery.discover(
                text: row.targetSentence,
                blockID: row.caseID)
            let isExplicitlyExcluded =
                row.shape == "override-markup"
                || row.shape == "capitalization"
                || row.shape == "heading-fragment"
            if let occurrence = discovered.first {
                #expect(
                    !isExplicitlyExcluded,
                    Comment(rawValue: row.caseID))
                #expect(occurrence.familyID == row.familyID)
                #expect(
                    occurrence.candidates.map(\.candidateID)
                        == family.candidates.map(\.candidateID))
            } else {
                #expect(
                    isExplicitlyExcluded || targetWordStart == nil,
                    Comment(rawValue: row.caseID))
            }

            let analysis: ContextualDeterministicAnalysis
            if row.shape == "override-markup" || targetWordStart == nil {
                analysis = .abstained
            } else {
                let wordStart = try #require(
                    targetWordStart,
                    Comment(rawValue: row.caseID))
                analysis = HomographPronunciationResolver.contextualAnalysis(
                    in: displayText,
                    wordStart: wordStart)
            }
            if analysis == .abstained {
                #expect(analysis.candidateID == nil)
                #expect(analysis.ruleID == nil)
            } else {
                #expect(
                    analysis.candidateID == row.expectedCandidateID,
                    Comment(rawValue: row.caseID))
                #expect(
                    analysis.strength
                        == (row.familyID == "content"
                            && analysis.candidateID == "content.satisfied"
                            ? .definitive : .advisory),
                    Comment(rawValue: row.caseID))
            }
            if let occurrence = discovered.first {
                #expect(occurrence.deterministicCandidateID == analysis.candidateID)
                #expect(occurrence.deterministicRuleID == analysis.ruleID)
                #expect(occurrence.deterministicStrength == analysis.strength)
            }
        }
    }

    @Test func everyMorphologyFixturePreservesFrozenProvenanceAcrossAuditCopies() throws {
        let rows = try jsonLines(
            MorphologyFixture.self,
            named: "morphology_v1.jsonl")
        let semanticPackVersion =
            "sha256:" + String(repeating: "0", count: 64)
        let vocabularyVersion =
            "sha256:" + String(repeating: "1", count: 64)
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion: semanticPackVersion,
            kokoroVocabularyVersion: vocabularyVersion,
            automaticEntries: [
                "available": ("cmudict.available.fixture", "əvˈeIləbəl")
            ])
        let known: [String: String] = [
            "start": "stˈɑɹt",
            "test": "tˈɛst",
            "reuse": "ɹiːjˈuːz",
            "digest": "daIdʒˈɛst",
            "deduct": "dɪdˈʌkt",
            "mir": "mˈɪɹ",
            "rate": "ɹˈeIt",
            "ratee": "ɹˈeItˌi",
            "comfort": "kˈʌmfɚt",
            "respons": "ɹɪspˈɑns",
            "live": "lˈɪv",
            "read": "ɹˈid",
            "record": "ɹəkˈɔɹd",
            "t": "tˈi",
        ]

        for row in rows {
            let sourceText =
                row.caseID == "morph-negative-proper-noun"
                ? "Meet \(row.word)."
                : "This synthetic sentence includes \(row.word) and enough "
                    + "extra words to force an immutable retry slice while "
                    + "preserving the exact pronunciation decision."
            let rewrite = UniversalPronunciationResolver.rewrite(
                to: sourceText,
                blockID: row.caseID,
                pack: pack,
                basePronunciation: { known[$0] })
            if !row.automatic {
                #expect(
                    rewrite.decisionSeeds.contains {
                        $0.source == .derivedMorphology
                    } == false,
                    Comment(rawValue: row.caseID))
                continue
            }

            let seed = try #require(
                rewrite.decisionSeeds.first,
                Comment(rawValue: row.caseID))
            #expect(seed.source == .derivedMorphology)
            #expect(seed.selectedIPA == row.expectedIPA)
            #expect(seed.derivationBase == row.expectedBase)
            #expect(seed.derivationRuleID == row.expectedRuleID)
            #expect(seed.candidateID?.isEmpty == false)
            #expect(
                seed.candidatePackVersion
                    == UniversalPronunciationResolver
                    .morphologyCandidatePackVersion(for: pack))

            let planned = try NarrationRenderPlanner.make(
                preparedBlocks: [
                    NarrationPreparedBlock(
                        block: block(id: row.caseID, text: rewrite.text),
                        pronunciationDecisionSeeds: rewrite.decisionSeeds)
                ],
                overrides: PronunciationOverrides(entries: [:]),
                pronunciationPack: pack)
            let plannedBlock = try #require(planned.blocks.first)
            let decision = try #require(
                plannedBlock.pronunciationDecisions.first {
                    $0.source == .derivedMorphology
                })
            #expect(decision.candidateID == seed.candidateID)
            #expect(decision.candidatePackVersion == seed.candidatePackVersion)
            #expect(decision.derivationBase == seed.derivationBase)
            #expect(decision.derivationRuleID == seed.derivationRuleID)
            #expect(decision.selectedIPA == seed.selectedIPA)

            let parent = try #require(plannedBlock.synthesisChunks.first)
            let retrySlices = parent.frozenRetrySlices(maxPhonemes: 32)
            #expect(!retrySlices.isEmpty)
            let retryEvidence =
                retrySlices
                .flatMap(\.pronunciationTokenEvidence)
                .first {
                    PronunciationAuditContext.normalizedWord($0.text)
                        == row.word
                }
            #expect(retryEvidence?.selectedPhonemes == decision.selectedIPA)
            let timed = decision.attachingRenderTiming(
                chapterIndex: 2,
                chapterRelativeAudioRange: .init(start: 1, end: 1.2),
                timingPrecision: .exactSynthesisWord
            ).attachingBookTiming(chapterIndex: 2, chapterOffset: 10)
            let manifest = PronunciationAuditManifest.make(
                renderVersion: NarrationFileNaming.renderVersion,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/synthetic.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [timed],
                diagnostics: [])
            let decoded = try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: manifest.encoded())
            let copied = try #require(decoded.decisions.first)
            #expect(copied.candidateID == seed.candidateID)
            #expect(copied.candidatePackVersion == seed.candidatePackVersion)
            #expect(copied.derivationBase == seed.derivationBase)
            #expect(copied.derivationRuleID == seed.derivationRuleID)
            #expect(copied.chapterRelativeAudioRange?.start == 1)
            #expect(copied.bookRelativeAudioRange?.start == 11)
        }
    }

    @Test func bundledPackHasClosedShapeAttributionAndIndependentIdentity() throws {
        let data = try Data(contentsOf: packURL)
        let pack = try EnglishPronunciationPack(data: data)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(root["entries"] as? [String: [[String: Any]]])
        let sources = try #require(root["sources"] as? [[String: Any]])
        let sourceIDs = sources.compactMap { $0["sourceID"] as? String }
        let exactCandidateFields: Set<String> = [
            "candidateID", "ipa", "lexicalClass", "senseLabel", "sourceID",
            "sourceTier", "kind", "automaticWithoutContext", "frequencyBand",
            "validationStatus",
        ]
        let closedStatuses: Set<String> = [
            "validated-automatic",
            "report-only-missing-sense-label",
            "validated-human-reviewed",
        ]
        var countedCandidates = 0

        for (word, candidates) in entries {
            countedCandidates += candidates.count
            for candidate in candidates {
                #expect(Set(candidate.keys) == exactCandidateFields)
                #expect(candidate["lexicalClass"] != nil)
                #expect(candidate["senseLabel"] != nil)
                let sourceID = try #require(candidate["sourceID"] as? String)
                #expect(sourceIDs.filter { $0 == sourceID }.count == 1)
                let status = try #require(candidate["validationStatus"] as? String)
                #expect(closedStatuses.contains(status))
                if status == "validated-human-reviewed" {
                    #expect(
                        (candidate["senseLabel"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty == false)
                }
            }

            let automatic = candidates.filter {
                $0["validationStatus"] as? String == "validated-automatic"
                    && $0["automaticWithoutContext"] as? Bool == true
            }
            if candidates.count == 1, automatic.count == 1 {
                #expect(
                    pack.automaticCandidate(for: word)?.candidateID
                        == automatic[0]["candidateID"] as? String)
            } else {
                #expect(pack.automaticCandidate(for: word) == nil)
            }
            if candidates.count > 1,
                candidates.allSatisfy({
                    $0["senseLabel"] is NSNull
                        && $0["validationStatus"] as? String
                            == "report-only-missing-sense-label"
                })
            {
                #expect(
                    candidates.allSatisfy {
                        $0["automaticWithoutContext"] as? Bool == false
                    })
            }
        }

        #expect(entries.count == pack.entryCount)
        #expect(countedCandidates == pack.candidateCount)
        #expect(pack.schemaVersion == 1)
        #expect(pack.dialect == "en-US")
        #expect(pack.sources.count == 3)
        #expect(pack.licenses.count == 1)
        #expect(!pack.requiredAcknowledgments.isEmpty)
        #expect(ISO8601DateFormatter().date(from: pack.generationTimestamp) != nil)
        #expect(
            [
                pack.generatorBehavior.generatorVersion,
                pack.generatorBehavior.normalizationPolicyVersion,
                pack.generatorBehavior.arpabetMappingVersion,
                pack.generatorBehavior.sourcePrecedencePolicyVersion,
                pack.generatorBehavior.automaticSelectionPolicyVersion,
                pack.generatorBehavior.candidateValidationPolicyVersion,
            ].allSatisfy { !$0.isEmpty })

        let entriesData = try JSONSerialization.data(withJSONObject: entries)
        let canonicalEntries = try JSONDecoder().decode(
            [String: [CanonicalCandidate]].self,
            from: entriesData)
        let entriesHash = sha256Identity(try canonicalData(canonicalEntries))
        #expect(entriesHash == pack.normalizedDataSHA256)
        let semanticPayload = try #require(
            root["semanticIdentityPayload"] as? [String: Any])
        #expect(
            sha256Identity(try canonicalData(semanticPayload))
                == pack.packVersion)

        var changedEntries = entries
        let firstWord = try #require(changedEntries.keys.sorted().first)
        var firstCandidates = try #require(changedEntries[firstWord])
        firstCandidates[0]["ipa"] = "changed"
        changedEntries[firstWord] = firstCandidates
        let changedEntriesData = try JSONSerialization.data(
            withJSONObject: changedEntries)
        let changedCanonicalEntries = try JSONDecoder().decode(
            [String: [CanonicalCandidate]].self,
            from: changedEntriesData)
        let changedEntriesHash = sha256Identity(
            try canonicalData(changedCanonicalEntries))
        #expect(changedEntriesHash != pack.normalizedDataSHA256)
        var changedPayload = semanticPayload
        changedPayload["normalizedDataSHA256"] = changedEntriesHash
        #expect(
            sha256Identity(try canonicalData(changedPayload))
                != pack.packVersion)

        for field in ["sourceSnapshots", "generatorBehavior", "kokoroVocabularyVersion"] {
            var mutation = semanticPayload
            mutation[field] = "changed"
            #expect(
                sha256Identity(try canonicalData(mutation))
                    != pack.packVersion)
        }

        let timestampA = EnglishPronunciationPack.emptyForTesting(
            packVersion: pack.packVersion,
            kokoroVocabularyVersion: pack.kokoroVocabularyVersion,
            generationTimestamp: "2026-07-29T00:00:00Z")
        let timestampB = EnglishPronunciationPack.emptyForTesting(
            packVersion: pack.packVersion,
            kokoroVocabularyVersion: pack.kokoroVocabularyVersion,
            generationTimestamp: "2026-07-30T00:00:00Z")
        #expect(timestampA.productionPolicySignature == timestampB.productionPolicySignature)
        #expect(
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: timestampA)
                == UniversalPronunciationResolver.morphologyCandidatePackVersion(
                    for: timestampB))
        #expect(root["generationTimestamp"] as? String == pack.generationTimestamp)
        #expect(semanticPayload["generationTimestamp"] == nil)
    }

    @Test func supplementalProvenanceRemainsSemanticAndNeverMorphological() throws {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:" + String(repeating: "2", count: 64),
            kokoroVocabularyVersion:
                "sha256:" + String(repeating: "3", count: 64),
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
            ])
        let rewrite = UniversalPronunciationResolver.rewrite(
            to: "A foobar appears in this synthetic fixture.",
            blockID: "supplemental-provenance",
            pack: pack,
            basePronunciation: { _ in nil })
        let seed = try #require(rewrite.decisionSeeds.first)
        #expect(rewrite.decisionSeeds.count == 1)
        #expect(seed.source == .supplementalLexicon)
        #expect(seed.candidateID == "cmudict.foobar.fixture")
        #expect(seed.candidatePackVersion == pack.packVersion)
        #expect(seed.derivationBase == nil)
        #expect(seed.derivationRuleID == nil)

        let planned = try NarrationRenderPlanner.make(
            preparedBlocks: [
                NarrationPreparedBlock(
                    block: block(
                        id: "supplemental-provenance",
                        text: rewrite.text),
                    pronunciationDecisionSeeds: rewrite.decisionSeeds)
            ],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: pack)
        let decision = try #require(
            planned.blocks.first?.pronunciationDecisions.first)
        #expect(decision.source == .supplementalLexicon)
        #expect(decision.candidateID == seed.candidateID)
        #expect(decision.candidatePackVersion == seed.candidatePackVersion)
        #expect(decision.derivationBase == nil)
        #expect(decision.derivationRuleID == nil)

        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/synthetic.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [decision],
            diagnostics: [])
        let roundTripped = try #require(
            JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: manifest.encoded()
            ).decisions.first)
        #expect(roundTripped.candidateID == seed.candidateID)
        #expect(roundTripped.candidatePackVersion == pack.packVersion)
        #expect(roundTripped.derivationBase == nil)
        #expect(roundTripped.derivationRuleID == nil)
    }

    @Test func unavailableShadowEvidenceCannotChangeProductionOrLeakContext() throws {
        let precedingSentence = "PrecedingWindowMarker."
        let targetSentence =
            "This deliberately extended synthetic target asks the tester to "
            + "please record one bounded result after many harmless words."
        let followingSentence = "FollowingWindowMarker."
        let text =
            "\(precedingSentence) \(targetSentence) \(followingSentence)"
        let sourceBlock = block(id: "shadow-unavailable", text: text)
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: sourceBlock.id
            ).first)
        let evidence = ContextualPronunciationEvidence(
            occurrenceID: occurrence.occurrenceID,
            familyID: occurrence.familyID,
            candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
            submittedCandidateIDs: occurrence.candidates.map(\.candidateID),
            deterministicCandidateID: occurrence.deterministicCandidateID,
            deterministicRuleID: occurrence.deterministicRuleID,
            deterministicStrength: occurrence.deterministicStrength,
            modelCandidateID: nil,
            modelAbstained: false,
            modelAvailability: .modelNotReady,
            modelFailure: nil,
            familyState: .shadow,
            acceptanceReason: .shadowModelUnavailable,
            promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
            platform: "program-acceptance",
            osBuild: "synthetic",
            qualifiedRuntimeFamilyID: "unavailable",
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        let omitted = try NarrationRenderPlanner.make(
            blocks: [sourceBlock],
            overrides: PronunciationOverrides(entries: [:]))
        let unavailable = try NarrationRenderPlanner.make(
            blocks: [sourceBlock],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [key: evidence],
            requiresContextualEvidence: true)
        let omittedBlock = try #require(omitted.blocks.first)
        let unavailableBlock = try #require(unavailable.blocks.first)

        #expect(omittedBlock.synthesisChunks == unavailableBlock.synthesisChunks)
        #expect(
            omittedBlock.pronunciationDecisions.map(\.selectedIPA)
                == unavailableBlock.pronunciationDecisions.map(\.selectedIPA))
        #expect(
            omittedBlock.pronunciationDecisions.map(\.kokoroTokenIDs)
                == unavailableBlock.pronunciationDecisions.map(\.kokoroTokenIDs))
        let omittedRenderedTexts = omitted.blocks.map {
            $0.synthesisChunks.map(\.g2pInputText).joined(separator: " ")
        }
        let unavailableRenderedTexts = unavailable.blocks.map {
            $0.synthesisChunks.map(\.g2pInputText).joined(separator: " ")
        }
        let omittedSignature = NarrationFileNaming.contentSignature(
            spokenBlocks: omitted.blocks.map(\.originalBlock),
            renderedTexts: omittedRenderedTexts,
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                EnglishPronunciationPack.empty.productionPolicySignature)
        let unavailableSignature = NarrationFileNaming.contentSignature(
            spokenBlocks: unavailable.blocks.map(\.originalBlock),
            renderedTexts: unavailableRenderedTexts,
            includeLeadOutPad: false,
            pronunciationPolicySignature:
                EnglishPronunciationPack.empty.productionPolicySignature)
        #expect(omittedSignature == unavailableSignature)

        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/synthetic.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: unavailableBlock.pronunciationDecisions,
            diagnostics: [])
        #expect(manifest.schemaVersion == 4)
        #expect(manifest.coverage == .complete)
        let missingEvidenceManifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/synthetic.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: omittedBlock.pronunciationDecisions,
            diagnostics: [])
        #expect(missingEvidenceManifest.schemaVersion == 4)
        #expect(missingEvidenceManifest.coverage == .incompleteEvidence)
        let encoded = try manifest.encoded()
        let encodedAuditString = String(decoding: encoded, as: UTF8.self)
        let forbiddenKeys = [
            "rawPrompt", "rawResponse", "bookTitle", "author",
            "userID", "localPath", "precedingSentence",
            "targetSentence", "followingSentence",
        ]
        for key in forbiddenKeys {
            #expect(!encodedAuditString.contains("\"\(key)\""))
        }
        let rawWindowValues = [
            precedingSentence,
            targetSentence,
            followingSentence,
            text,
        ]
        for value in rawWindowValues {
            #expect(!encodedAuditString.contains(value))
        }
    }
}
