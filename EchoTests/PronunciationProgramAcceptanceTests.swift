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
        let precedingSentence: String?
        let targetSentence: String
        let followingSentence: String?
        let expectedCandidateID: String
        let expectedOutcome: String
        let expectedOutcomePolicyMode: String
        let expectedDiscoveryState: String
        let expectedAnalyzerState: String
    }

    /// The acceptance-policy mode the frozen outcome column encodes.
    ///
    /// §9.1's fifth clause — deterministic and model agreement on a graduated
    /// family — is inert while every family is shadow-only, and goes live at
    /// Phase 3. Without naming the mode, the frozen values would silently
    /// become wrong exactly when §13.3 uses them to gate graduation.
    private enum OutcomePolicyMode: String {
        case phaseTwoShadowDeterministicOnly =
            "phase2-shadow-deterministic-only"
    }

    /// The three-sentence context a named row is authored to exercise.
    ///
    /// `misleading-adjacent-cue` rows exist to prove an adjacent sentence
    /// does not fool resolution, so the adjacent sentences must actually
    /// reach discovery and the analyzer. The target's word index is resolved
    /// inside the target sentence and then offset, because a preceding
    /// sentence may legitimately contain the same spelling.
    private struct NamedWindow {
        let source: String
        let displayText: String
        let words: [String]
        let targetWordStart: Int?
    }

    private func namedWindow(for row: NamedFixture) -> NamedWindow {
        let sentences = [
            row.precedingSentence,
            row.targetSentence,
            row.followingSentence,
        ].compactMap { $0 }
        let source = sentences.joined(separator: " ")
        let displayText = MisakiPronunciationMarkup.displayText(from: source)
        let words = WordTokenizer.words(in: displayText).map(String.init)
        let precedingWordCount = row.precedingSentence.map {
            WordTokenizer.words(
                in: MisakiPronunciationMarkup.displayText(from: $0)
            ).count
        } ?? 0
        let targetDisplay = MisakiPronunciationMarkup.displayText(
            from: row.targetSentence)
        let normalizedTarget = row.targetWord.lowercased()
        let indexInTarget = WordTokenizer.words(in: targetDisplay)
            .map(String.init)
            .firstIndex {
                PronunciationAuditContext.normalizedWord($0) == normalizedTarget
            }
        return NamedWindow(
            source: source,
            displayText: displayText,
            words: words,
            targetWordStart: indexInTarget.map { $0 + precedingWordCount })
    }

    /// True when the row carries Misaki override markup on the target word.
    private func overrideApplies(to row: NamedFixture) -> Bool {
        let source = row.targetSentence
        let normalizedTarget = row.targetWord.lowercased()
        var index = source.startIndex
        while index < source.endIndex {
            if let link = MisakiPronunciationMarkup.link(
                in: source,
                startingAt: index)
            {
                let display = String(link.displayText)
                if PronunciationAuditContext.normalizedWord(display)
                    == normalizedTarget
                {
                    return true
                }
                index = link.range.upperBound
            } else {
                index = source.index(after: index)
            }
        }
        return false
    }

    /// Spec §9.1/§9.2 evaluated in one named acceptance-policy mode.
    ///
    /// §9.1 lists five automatic routes. In
    /// `phase2-shadow-deterministic-only` two of them cannot fire and are
    /// therefore not parameters here:
    ///
    /// - "one graduated, validated morphology candidate" cannot apply,
    ///   because every target is a contextual homograph rather than a
    ///   derived form, and morphology abstains on any spelling with an
    ///   explicit source candidate.
    /// - "deterministic and model agreement for a graduated contextual
    ///   family on a qualified runtime" cannot apply, because no family is
    ///   graduated and §9.2's closing rule makes the model non-acceptance
    ///   evidence while a family is shadow-only.
    ///
    /// The three that can fire are passed in. Everything else is §9.2 review.
    /// A different mode must be added explicitly rather than by reusing this
    /// evaluation.
    private func hypotheticalAcceptanceOutcome(
        mode: OutcomePolicyMode,
        overrideApplies: Bool,
        strength: DeterministicRuleStrength,
        hasUnambiguousLexiconCandidate: Bool
    ) -> String {
        switch mode {
        case .phaseTwoShadowDeterministicOnly:
            if overrideApplies || strength == .definitive
                || hasUnambiguousLexiconCandidate
            {
                return "automatic"
            }
            return "review"
        }
    }

    private struct MorphologyFixture: Decodable {
        let caseID: String
        let word: String
        let expectedBase: String?
        let expectedRuleID: String?
        let expectedIPA: String?
        let expectedCandidateID: String?
        let expectedCandidatePackVersion: String?
        let automatic: Bool
    }

    private struct IndependentMorphologyPolicy: Encodable {
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

    private struct MorphologyCandidateProbe {
        let word: String
        let base: String
        let ruleID: String
        let baseIPA: String
        let derivedIPA: String
        let candidatePackVersion: String
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
        #expect(named.count == 37)
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
        let pack = try EnglishPronunciationPack(
            data: try Data(contentsOf: packURL))
        var discoveryCounts = ["discovered": 0, "excluded": 0]
        var analyzerCounts = ["definitive": 0, "advisory": 0, "abstained": 0]
        var outcomeCounts = ["automatic": 0, "review": 0]

        for row in rows {
            let normalizedTarget = row.targetWord.lowercased()
            let family = try #require(
                ContextualPronunciationFamilies.family(for: normalizedTarget))
            #expect(family.familyID == row.familyID, Comment(rawValue: row.caseID))
            #expect(
                family.candidates.map(\.candidateID).contains(
                    row.expectedCandidateID),
                Comment(rawValue: row.caseID))

            let window = namedWindow(for: row)
            if let wordStart = window.targetWordStart {
                // The offset index must still name the target inside the
                // composed window, otherwise the analyzer would be handed an
                // unrelated word.
                #expect(
                    PronunciationAuditContext.normalizedWord(
                        window.words[wordStart]) == normalizedTarget,
                    Comment(rawValue: "\(row.caseID): window index"))
            }

            let discovered = ContextualPronunciationDiscovery.discover(
                text: window.source,
                blockID: row.caseID)
            let targetOccurrence = window.targetWordStart.flatMap { start in
                discovered.first { $0.wordStart == start }
            }
            let actualDiscoveryState =
                targetOccurrence == nil ? "excluded" : "discovered"
            discoveryCounts[actualDiscoveryState, default: 0] += 1
            #expect(
                actualDiscoveryState == row.expectedDiscoveryState,
                Comment(
                    rawValue:
                        "\(row.caseID): discovery \(actualDiscoveryState)"))
            if let occurrence = targetOccurrence {
                #expect(occurrence.familyID == row.familyID)
                #expect(
                    occurrence.candidates.map(\.candidateID)
                        == family.candidates.map(\.candidateID))
            }

            // Production analysis runs on every row, including
            // `override-markup`. Asserting a literal `.abstained` there
            // proved nothing about the override-authority invariant.
            let analysis: ContextualDeterministicAnalysis
            if let wordStart = window.targetWordStart {
                analysis = HomographPronunciationResolver.contextualAnalysis(
                    in: window.displayText,
                    wordStart: wordStart)
            } else {
                analysis = .abstained
            }
            analyzerCounts[analysis.strength.rawValue, default: 0] += 1
            #expect(
                analysis.strength.rawValue == row.expectedAnalyzerState,
                Comment(
                    rawValue:
                        "\(row.caseID): analyzer \(analysis.strength.rawValue)"))
            if analysis == .abstained {
                #expect(analysis.candidateID == nil)
                #expect(analysis.ruleID == nil)
            } else {
                #expect(
                    analysis.candidateID == row.expectedCandidateID,
                    Comment(
                        rawValue:
                            "\(row.caseID): candidate "
                            + (analysis.candidateID ?? "nil")))
            }
            if let occurrence = targetOccurrence {
                #expect(occurrence.deterministicCandidateID == analysis.candidateID)
                #expect(occurrence.deterministicRuleID == analysis.ruleID)
                #expect(occurrence.deterministicStrength == analysis.strength)
            }

            let overrideApplies = overrideApplies(to: row)
            #expect(
                overrideApplies == (row.shape == "override-markup"),
                Comment(rawValue: "\(row.caseID): override \(overrideApplies)"))
            // The production invariant is the resolver's exclusion set, which
            // refuses these spellings *before* the pack is consulted. The
            // pack's silence on them is incidental — it is supplemental and
            // excludes tens of thousands of gold spellings — so asserting
            // only the pack would prove the wrong thing.
            #expect(
                UniversalPronunciationResolver.contextualExclusions.contains(
                    normalizedTarget),
                Comment(rawValue: "\(row.caseID): contextual exclusion"))
            let unambiguousLexiconCandidate =
                !UniversalPronunciationResolver.contextualExclusions.contains(
                    normalizedTarget)
                && pack.automaticCandidate(for: normalizedTarget) != nil
            #expect(
                !unambiguousLexiconCandidate,
                Comment(rawValue: "\(row.caseID): lexicon candidate"))

            let mode = try #require(
                OutcomePolicyMode(rawValue: row.expectedOutcomePolicyMode),
                Comment(rawValue: "\(row.caseID): unknown policy mode"))
            #expect(
                mode == .phaseTwoShadowDeterministicOnly,
                Comment(rawValue: "\(row.caseID): evaluated mode"))
            let outcome = hypotheticalAcceptanceOutcome(
                mode: mode,
                overrideApplies: overrideApplies,
                strength: analysis.strength,
                hasUnambiguousLexiconCandidate: unambiguousLexiconCandidate)
            outcomeCounts[outcome, default: 0] += 1
            #expect(
                outcome == row.expectedOutcome,
                Comment(rawValue: "\(row.caseID): outcome \(outcome)"))
        }
        #expect(discoveryCounts == ["discovered": 21, "excluded": 16])
        // Exactly one row exercises the only promoted definitive rule
        // (`homograph.content.adjective.copula`). Freezing that count at zero
        // let the `content` family pass its §13.3 named gate without ever
        // running its own rule, and left the `.definitive` branch of the
        // outcome derivation dead with respect to this matrix.
        #expect(
            analyzerCounts
                == ["definitive": 1, "advisory": 13, "abstained": 23])
        #expect(outcomeCounts == ["automatic": 5, "review": 32])
    }

    @Test func everyMorphologyFixturePreservesFrozenProvenanceAcrossAuditCopies() throws {
        let rows = try jsonLines(
            MorphologyFixture.self,
            named: "morphology_v1.jsonl")
        let semanticPackVersion =
            "sha256:" + String(repeating: "0", count: 64)
        let vocabularyVersion =
            "sha256:" + String(repeating: "1", count: 64)
        let frozenMorphologyPackVersion =
            "morphology-v1:sha256:"
            + "58523e5570d98308c8f233be1e1cadb6c0f32079f54725f87ddabaa4151ca5d9"
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
            #expect(seed.candidateID == row.expectedCandidateID)
            #expect(
                seed.candidatePackVersion
                    == row.expectedCandidatePackVersion)
            #expect(seed.candidatePackVersion == frozenMorphologyPackVersion)

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

        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func sha256(_ data: Data) -> String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        let frozenRules = [
            "morphology.able.exact-base.v1",
            "morphology.able.silent-e.v1",
            "morphology.ible.exact-base.v1",
        ]
        let frozenExceptions: Set<String> = [
            "comfortable", "content", "livable", "live", "lives", "read",
            "readable", "record", "recordable", "records", "responsible",
        ]
        func independentMorphologyPolicy(
            semanticPackVersion: String = semanticPackVersion,
            vocabularyVersion: String = vocabularyVersion,
            ruleIDs: [String] = frozenRules,
            exceptionWords: Set<String> = frozenExceptions,
            baseEvidencePolicyVersion: String =
                "kokoro-nonfallback-rating3-v1"
        ) throws -> String {
            let exceptionData = try canonicalEncoder.encode(
                Array(exceptionWords).sorted())
            let payload = IndependentMorphologyPolicy(
                identitySchemaVersion: 1,
                morphologyVersion: "morphology-v1",
                ruleIDs: ruleIDs.sorted(),
                suffixIPA: "əbəl",
                minimumBaseLength: 3,
                properNamePolicyVersion: "proper-name-risk-v7",
                baseEvidencePolicyVersion: baseEvidencePolicyVersion,
                exceptionSetSHA256: "sha256:\(sha256(exceptionData))",
                pronunciationPackVersion: semanticPackVersion,
                kokoroVocabularyVersion: vocabularyVersion)
            return "morphology-v1:sha256:"
                + sha256(try canonicalEncoder.encode(payload))
        }
        func independentCandidateID(
            _ input: MorphologyCandidateProbe
        ) -> String {
            let fields = [
                input.candidatePackVersion, input.word, input.base,
                input.ruleID, input.baseIPA, input.derivedIPA,
            ]
            let digest = sha256(
                Data(fields.joined(separator: "\0").utf8))
            return "morphology.\(input.word).\(digest.prefix(12))"
        }
        func actualCacheSignature(
            _ input: MorphologyCandidateProbe
        ) -> String {
            let rendered = "[\(input.word)](/\(input.derivedIPA)/)"
            return NarrationFileNaming.contentSignature(
                spokenBlocks: [
                    block(id: "morphology-cache", text: input.word)
                ],
                renderedTexts: [rendered],
                includeLeadOutPad: false,
                pronunciationPolicySignature: [
                    semanticPackVersion,
                    input.candidatePackVersion,
                    EnglishPronunciationPack.contentDefaultPolicyVersion,
                ].joined(separator: "|"))
        }
        func plannedDecision(
            _ input: MorphologyCandidateProbe
        ) throws -> PronunciationAuditDecision {
            let candidateID = independentCandidateID(input)
            let rendered = "[\(input.word)](/\(input.derivedIPA)/)"
            let seed = PronunciationDecisionSeed(
                blockID: "morphology-plan",
                wordStart: 0,
                wordEnd: 0,
                normalizedWord: input.word,
                sourceWord: input.word,
                sourceContext: input.word,
                selectedIPA: input.derivedIPA,
                source: .derivedMorphology,
                ruleID: input.ruleID,
                rationale: "Synthetic acceptance identity probe.",
                candidateID: candidateID,
                candidatePackVersion: input.candidatePackVersion,
                derivationBase: input.base,
                derivationRuleID: input.ruleID)
            let plan = try NarrationRenderPlanner.make(
                preparedBlocks: [
                    NarrationPreparedBlock(
                        block: block(
                            id: "morphology-plan",
                            text: rendered),
                        pronunciationDecisionSeeds: [seed])
                ],
                overrides: PronunciationOverrides(entries: [:]),
                pronunciationPack: pack)
            return try #require(
                plan.blocks.first?.pronunciationDecisions.first)
        }

        let baselinePolicy =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: pack)
        let independentlyRebuiltBaseline =
            try independentMorphologyPolicy()
        #expect(independentlyRebuiltBaseline == frozenMorphologyPackVersion)
        #expect(baselinePolicy == frozenMorphologyPackVersion)
        let changedRule =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: pack,
                ruleIDs: [
                    "morphology.able.exact-base.v2",
                    "morphology.able.silent-e.v1",
                    "morphology.ible.exact-base.v1",
                ])
        let changedException =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: pack,
                exceptionWords:
                    UniversalPronunciationResolver.exceptionWords.union([
                        "changeable"
                    ]))
        let changedBaseEvidence =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: pack,
                baseEvidencePolicyVersion: "kokoro-nonfallback-rating4-v2")
        let changedSemanticPack = EnglishPronunciationPack.emptyForTesting(
            packVersion: "sha256:" + String(repeating: "2", count: 64),
            kokoroVocabularyVersion: vocabularyVersion)
        let changedVocabularyPack = EnglishPronunciationPack.emptyForTesting(
            packVersion: semanticPackVersion,
            kokoroVocabularyVersion:
                "sha256:" + String(repeating: "3", count: 64))
        let changedSemanticIdentity =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: changedSemanticPack)
        let changedVocabularyIdentity =
            UniversalPronunciationResolver.morphologyCandidatePackVersion(
                for: changedVocabularyPack)
        let independentlyChangedRule = try independentMorphologyPolicy(
            ruleIDs: [
                "morphology.able.exact-base.v2",
                "morphology.able.silent-e.v1",
                "morphology.ible.exact-base.v1",
            ])
        let independentlyChangedException =
            try independentMorphologyPolicy(
                exceptionWords: frozenExceptions.union(["changeable"]))
        let independentlyChangedBaseEvidence =
            try independentMorphologyPolicy(
                baseEvidencePolicyVersion: "kokoro-nonfallback-rating4-v2")
        let independentlyChangedSemantic =
            try independentMorphologyPolicy(
                semanticPackVersion:
                    "sha256:" + String(repeating: "2", count: 64))
        let independentlyChangedVocabulary =
            try independentMorphologyPolicy(
                vocabularyVersion:
                    "sha256:" + String(repeating: "3", count: 64))
        #expect(changedRule == independentlyChangedRule)
        #expect(changedException == independentlyChangedException)
        #expect(changedBaseEvidence == independentlyChangedBaseEvidence)
        #expect(changedSemanticIdentity == independentlyChangedSemantic)
        #expect(changedVocabularyIdentity == independentlyChangedVocabulary)
        let policyIdentities = [
            baselinePolicy,
            changedRule,
            changedException,
            changedBaseEvidence,
            changedSemanticIdentity,
            changedVocabularyIdentity,
        ]
        #expect(Set(policyIdentities).count == policyIdentities.count)

        func policyCacheSignature(
            semanticPackVersion: String,
            morphologyPolicy: String
        ) -> String {
            NarrationFileNaming.contentSignature(
                spokenBlocks: [
                    block(
                        id: "morphology-policy-cache",
                        text: "Synthetic morphology cache probe.")
                ],
                renderedTexts: ["Synthetic morphology cache probe."],
                includeLeadOutPad: false,
                pronunciationPolicySignature: [
                    semanticPackVersion,
                    morphologyPolicy,
                    EnglishPronunciationPack.contentDefaultPolicyVersion,
                ].joined(separator: "|"))
        }
        let policyCacheSignatures = [
            policyCacheSignature(
                semanticPackVersion: semanticPackVersion,
                morphologyPolicy: baselinePolicy),
            policyCacheSignature(
                semanticPackVersion: semanticPackVersion,
                morphologyPolicy: changedRule),
            policyCacheSignature(
                semanticPackVersion: semanticPackVersion,
                morphologyPolicy: changedException),
            policyCacheSignature(
                semanticPackVersion: semanticPackVersion,
                morphologyPolicy: changedBaseEvidence),
            policyCacheSignature(
                semanticPackVersion: changedSemanticPack.packVersion,
                morphologyPolicy: changedSemanticIdentity),
            policyCacheSignature(
                semanticPackVersion: changedVocabularyPack.packVersion,
                morphologyPolicy: changedVocabularyIdentity),
        ]
        #expect(
            Set(policyCacheSignatures).count
                == policyCacheSignatures.count)

        let candidateInputs: [MorphologyCandidateProbe] = [
            MorphologyCandidateProbe(
                word: "startable",
                base: "start",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: baselinePolicy
            ),
            MorphologyCandidateProbe(
                word: "testable",
                base: "start",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: baselinePolicy
            ),
            MorphologyCandidateProbe(
                word: "startable",
                base: "test",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: baselinePolicy
            ),
            MorphologyCandidateProbe(
                word: "startable",
                base: "start",
                ruleID: "morphology.able.silent-e.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: changedRule
            ),
            MorphologyCandidateProbe(
                word: "startable",
                base: "start",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹd",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: baselinePolicy
            ),
            MorphologyCandidateProbe(
                word: "startable",
                base: "start",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtɪbəl",
                candidatePackVersion: baselinePolicy
            ),
            MorphologyCandidateProbe(
                word: "startable",
                base: "start",
                ruleID: "morphology.able.exact-base.v1",
                baseIPA: "stˈɑɹt",
                derivedIPA: "stˈɑɹtəbəl",
                candidatePackVersion: changedSemanticIdentity
            ),
        ]
        let independentCandidateIDs =
            candidateInputs.map(independentCandidateID)
        let productionCandidateIDs = candidateInputs.map {
            UniversalPronunciationResolver.derivedCandidateID(
                normalizedWord: $0.word,
                derivationBase: $0.base,
                derivationRuleID: $0.ruleID,
                baseIPA: $0.baseIPA,
                derivedIPA: $0.derivedIPA,
                candidatePackVersion: $0.candidatePackVersion)
        }
        #expect(
            independentCandidateIDs
                == productionCandidateIDs)
        #expect(
            productionCandidateIDs[0]
                == "morphology.startable.14f4cfb4f8f1")
        #expect(
            Set(productionCandidateIDs).count
                == productionCandidateIDs.count)

        let plannedDecisions = try candidateInputs.map(plannedDecision)
        for index in candidateInputs.indices {
            #expect(
                plannedDecisions[index].candidateID
                    == productionCandidateIDs[index])
            #expect(
                plannedDecisions[index].candidatePackVersion
                    == candidateInputs[index].candidatePackVersion)
            #expect(
                plannedDecisions[index].derivationBase
                    == candidateInputs[index].base)
            #expect(
                plannedDecisions[index].derivationRuleID
                    == candidateInputs[index].ruleID)
            #expect(
                plannedDecisions[index].selectedIPA
                    == candidateInputs[index].derivedIPA)
        }

        let candidateCacheSignatures =
            candidateInputs.map(actualCacheSignature)
        #expect(candidateCacheSignatures[1] != candidateCacheSignatures[0])
        #expect(candidateCacheSignatures[2] == candidateCacheSignatures[0])
        #expect(candidateCacheSignatures[3] != candidateCacheSignatures[0])
        #expect(candidateCacheSignatures[4] == candidateCacheSignatures[0])
        #expect(candidateCacheSignatures[5] != candidateCacheSignatures[0])
        #expect(candidateCacheSignatures[6] != candidateCacheSignatures[0])
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
