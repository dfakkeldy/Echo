// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationRenderPlanTests {
    private func block(
        id: String,
        text: String?,
        kind: String = "paragraph",
        index: Int
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: index, sequenceIndex: index,
            blockKind: kind, text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func plannedDecisionUsesExactFinalChunkPhonemeAndIDSlice() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "The process is startable.", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)
        let evidence = try #require(
            chunk.pronunciationTokenEvidence.first {
                PronunciationAuditContext.normalizedWord($0.text) == "startable"
            })
        let phonemeRange = try #require(evidence.phonemeCharacterRange)
        let lowerBound = chunk.phonemes.index(
            chunk.phonemes.startIndex,
            offsetBy: phonemeRange.lowerBound)
        let upperBound = chunk.phonemes.index(
            chunk.phonemes.startIndex,
            offsetBy: phonemeRange.upperBound)
        let exactFinalIPA = String(chunk.phonemes[lowerBound..<upperBound])
        let interiorIDs = Array(chunk.phonemeIDs.dropFirst().dropLast())
        let exactFinalIDs = Array(interiorIDs[phonemeRange])

        #expect(decision.blockID == "b0")
        #expect(decision.wordStart == 3)
        #expect(decision.wordEnd == 3)
        #expect(decision.normalizedWord == "startable")
        #expect(decision.sourceWord == "startable")
        #expect(decision.sourceContext == "The process is startable.")
        #expect(exactFinalIPA == "stˈɑɹTəbəl")
        #expect(decision.selectedIPA == exactFinalIPA)
        #expect(decision.kokoroTokenIDs == exactFinalIDs)
        #expect(!decision.kokoroTokenIDs.isEmpty)
        #expect(decision.kokoroTokenIDs.allSatisfy { $0 != KokoroPhonemeVocab.boundaryTokenId })
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.startable")
        #expect(decision.rationale == "Built-in override matched “startable”.")
        #expect(decision.chapterIndex == nil)
        #expect(decision.chapterRelativeAudioRange == nil)
        #expect(decision.bookRelativeAudioRange == nil)
        #expect(decision.timingPrecision == nil)

        let encoded = try JSONEncoder().encode(decision)
        #expect(
            try JSONDecoder().decode(PronunciationAuditDecision.self, from: encoded) == decision)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"source\":\"builtInOverride\""))
    }

    @Test func quotedSentenceBoundaryPreservesAuditWordIndexes() throws {
        let text =
            "You open an assistant and ask it to rewrite a paragraph. It does a decent job. "
            + "You reply, “Make it less formal.” The second answer usually makes sense even "
            + "though you did not paste the paragraph again. Something from the earlier "
            + "exchange remained available."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "quoted-boundary", text: text, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "available"
            })

        #expect(
            plannedBlock.synthesisChunks.reduce(0) { $0 + $1.wordCount }
                == WordTokenizer.words(in: text).count)
        #expect(decision.wordStart == 43)
        #expect(decision.wordEnd == 43)
        #expect(decision.sourceContext == "from the earlier exchange remained available.")
    }

    @Test func normalizedDashAndHTMLCommentPreserveAuditEvidence() throws {
        let text =
            "Is it ready? — The filesystem lives here; agents live here. "
            + "<!-- G088 --> Re-check the startable system."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "reported-seams", text: text, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let decisions = Dictionary(
            uniqueKeysWithValues: plannedBlock.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
        #expect(decisions["filesystem"]?.source == .builtInOverride)
        #expect(decisions["startable"]?.source == .builtInOverride)
        #expect(decisions["re"]?.source == .builtInOverride)
        #expect(decisions["live"]?.source == .contextualHomograph)
        #expect(decisions["lives"]?.source == .contextualHomograph)
        #expect(
            plannedBlock.synthesisChunks.reduce(0) { $0 + $1.wordCount }
                == WordTokenizer.words(in: TextNormalizer.normalize(text)).count)
    }

    @Test func lifecycleOverrideKeepsCompleteEvidenceBesideClaudeMarkdownToken() throws {
        let text =
            "Different backgrounds create different gaps. An experienced backend architect may "
            + "already understand queues, retries, access control, and observability while "
            + "remaining unfamiliar with model-driven tool selection or context limits. A daily "
            + "Claude Code user may know how to steer a coding session yet never have implemented "
            + "the API loop that passes a tool result back to Claude. An engineer who has built an "
            + "extraction service may understand schemas and evaluation while having little "
            + "experience with shared CLAUDE.md files, lifecycle hooks, or isolated subagents. "
            + "Each person has transferable strengths. Each still needs direct practice in the "
            + "missing domains."
        let overrides = PronunciationOverrides.withBuiltInDefaults([:])
        let rewrite = overrides.rewrite(
            to: TextNormalizer.normalize(text),
            blockID: "reported-lifecycle")
        let rewriteLifecycle = try #require(
            rewrite.decisionSeeds.first {
                $0.normalizedWord == "lifecycle"
            })
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "reported-lifecycle", text: text, index: 0)],
            overrides: overrides)
        let plannedBlock = try #require(plan.blocks.first)
        let lifecycle = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "lifecycle"
            })

        #expect(lifecycle.wordStart == rewriteLifecycle.wordStart)
        #expect(lifecycle.wordEnd == rewriteLifecycle.wordEnd)
        #expect(lifecycle.source == .builtInOverride)
        #expect(lifecycle.ruleID == "override.built-in.lifecycle")
        #expect(lifecycle.selectedIPA == "lˈIfsˌIkəl")
        #expect(plannedBlock.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func aggregatePhonemeMismatchSuppressesDecisionAndMakesAuditIncomplete() throws {
        let validation = PronunciationEvidenceValidator.validate(
            snapshots: [
                PronunciationEvidenceValidator.Snapshot(
                    text: "startable",
                    whitespace: "",
                    selectedPhonemes: "stˈɑɹɾəbᵊl",
                    lexicalTag: "Noun",
                    rating: 5)
            ],
            displayText: "startable",
            finalPhonemes: "stˈɑɹTəbᵊl")
        let chunk = PlannedSynthesisChunk(
            displayText: "startable",
            g2pInputText: "[startable](/stˈɑɹɾəbᵊl/)",
            phonemes: "stˈɑɹTəbᵊl",
            phonemeIDs: [KokoroPhonemeVocab.boundaryTokenId]
                + Array(repeating: 1, count: "stˈɑɹTəbᵊl".count)
                + [KokoroPhonemeVocab.boundaryTokenId],
            wordCount: 1,
            pronunciationFallbackHits: [],
            pronunciationTokenEvidence: validation.evidence,
            pronunciationEvidenceValidation: validation.validation)
        let seed = PronunciationDecisionSeed(
            blockID: "mismatch",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "startable",
            selectedIPA: "stˈɑɹɾəbᵊl",
            source: .builtInOverride,
            ruleID: "override.built-in.startable",
            rationale: "Built-in override matched “startable”.")
        let materialization = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [seed],
            synthesisChunks: [chunk])
        let plannedBlock = NarrationPlannedBlock(
            blockID: "mismatch",
            originalBlock: block(id: "mismatch", text: "startable", index: 0),
            synthesisChunks: [chunk],
            pronunciationDecisions: materialization.decisions,
            pronunciationDecisionDiagnostics: materialization.diagnostics,
            trailingSilence: nil)
        let diagnostic = try #require(plannedBlock.pronunciationAuditDiagnostics.first)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/mismatch.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["startable"],
            decisions: materialization.decisions,
            diagnostics: plannedBlock.pronunciationAuditDiagnostics)

        #expect(validation.evidence.isEmpty)
        #expect(materialization.decisions.isEmpty)
        #expect(materialization.diagnostics.isEmpty)
        #expect(diagnostic.reason == .phonemeSequenceMismatch)
        #expect(diagnostic.finalPhonemes == "stˈɑɹTəbᵊl")
        #expect(diagnostic.reconstructedTokenPhonemes == "stˈɑɹɾəbᵊl")
        #expect(manifest.coverage == .incompleteEvidence)
    }

    @Test func rawBleUserOverrideMatchesFinalPreTTSPhonemesAndReceipt() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "possible", text: "This is possible.", index: 0)],
            overrides: PronunciationOverrides(entries: ["possible": "pˈɑsəbᵊl"]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)
        let expectedIPA = "pˈɑsəbəl"
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: expectedIPA)

        #expect(chunk.g2pInputText == "This is [possible](/pˈɑsəbᵊl/).")
        #expect(chunk.phonemes.contains(expectedIPA))
        #expect(!chunk.phonemes.contains("bᵊl"))
        #expect(decision.selectedIPA == expectedIPA)
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(plannedBlock.pronunciationDecisionDiagnostics.isEmpty)
    }

    @Test func sameSpanWrongFinalIPASuppressesRuleAndMakesAuditIncomplete() throws {
        let chunk = try PronunciationPlanner().planResolved("[record](/ɹəkˈɔɹd/)")
        let seed = PronunciationDecisionSeed(
            blockID: "wrong-ipa",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "record",
            selectedIPA: "ɹˈɛkəɹd",
            source: .contextualHomograph,
            ruleID: "homograph.record.noun.fallback",
            rationale: "Noun pronunciation selected for “record”.")
        let materialization = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [seed],
            synthesisChunks: [chunk])
        let plannedBlock = NarrationPlannedBlock(
            blockID: "wrong-ipa",
            originalBlock: block(id: "wrong-ipa", text: "record", index: 0),
            synthesisChunks: [chunk],
            pronunciationDecisions: materialization.decisions,
            pronunciationDecisionDiagnostics: materialization.diagnostics,
            trailingSilence: nil)
        let diagnostic = try #require(plannedBlock.pronunciationAuditDiagnostics.first)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/wrong-ipa.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["record"],
            decisions: materialization.decisions,
            diagnostics: plannedBlock.pronunciationAuditDiagnostics)

        #expect(materialization.decisions.isEmpty)
        #expect(materialization.diagnostics.count == 1)
        #expect(diagnostic.reason == .decisionEvidenceMismatch)
        #expect(diagnostic.finalPhonemes == "ɹəkˈɔɹd")
        #expect(manifest.coverage == .incompleteEvidence)
    }

    @Test func decisionSourceRawValuesAreStableSchemaValues() {
        let sources: [PronunciationAuditDecision.Source] = [
            .occurrenceOverride,
            .bookOverride,
            .globalOverride,
            .builtInOverride,
            .contextualHomograph,
            .monitoredLexicon,
            .fallback,
        ]

        #expect(
            sources.map(\.rawValue) == [
                "occurrenceOverride",
                "bookOverride",
                "globalOverride",
                "builtInOverride",
                "contextualHomograph",
                "monitoredLexicon",
                "fallback",
            ])
    }

    @Test func preparedOccurrenceDecisionWinsOverBookOverride() throws {
        let sourceBlock = block(id: "b0", text: "The content stays here.", index: 0)
        let occurrence = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "b0",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ]).rewrite(to: sourceBlock.text ?? "", blockID: "b0")
        var rewrittenBlock = sourceBlock
        rewrittenBlock.text = occurrence.text
        let prepared = NarrationPreparedBlock(
            block: rewrittenBlock,
            pronunciationDecisionSeeds: occurrence.decisionSeeds)

        let plan = try NarrationRenderPlanner.make(
            preparedBlocks: [prepared],
            overrides: PronunciationOverrides(
                entries: ["content": "kəntˈɛnt"],
                source: .bookOverride))

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .occurrenceOverride)
        #expect(decision.selectedIPA == "kˈɑntɛnt")
        #expect(
            plan.blocks.first?.synthesisChunks.first?.g2pInputText.contains("[content](/kˈɑntɛnt/)")
                == true)
    }

    @Test func standaloneContentHeadingUsesMaterialNounFallback() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "heading", text: "Content", kind: "heading", index: 0)],
            overrides: PronunciationOverrides(entries: [:]))

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "content"
            })

        #expect(chunk.displayText == "Content")
        #expect(chunk.g2pInputText == "Content")
        #expect(chunk.phonemes == "kˈɑntɛnt")
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.ruleID == "g2p.lexicon.content")
        #expect(decision.selectedIPA == "kˈɑntɛnt")
    }

    @Test func bookOverrideWinsOverGlobalOverrideWithBookProvenance() throws {
        let overrides = PronunciationOverrides.merging(
            global: PronunciationOverrides(entries: ["record": "ɹˈɛkəɹd"]),
            book: ["record": "ɹəkˈɔɹd"])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "Please record the result.", index: 0)],
            overrides: overrides)

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .bookOverride)
        #expect(decision.ruleID == "override.book.record")
        #expect(decision.selectedIPA == "ɹəkˈɔɹd")
    }

    @Test func globalOverrideWinsOverBuiltInWithGlobalProvenance() throws {
        let overrides = PronunciationOverrides.withBuiltInDefaults([
            "STARTABLE": "stˈɑɹtəbəl"
        ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "The process is startable.", index: 0)],
            overrides: overrides)

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .globalOverride)
        #expect(decision.ruleID == "override.global.startable")
        #expect(decision.selectedIPA == "stˈɑɹtəbəl")
    }

    @Test func builtInScopedOverrideWinsOverContextualResolution() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "Please record the result.", index: 0)],
            overrides: PronunciationOverrides(
                entries: ["record": "ɹˈɛkəɹd"],
                source: .builtInOverride))

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.record")
        #expect(decision.selectedIPA == "ɹˈɛkəɹd")
    }

    @Test func auditsSixWordWatchMatrixAndFallbackFromPlannedChunks() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "watch",
                    text:
                        "The process is startable. The filesystem was verified. "
                        + "They live there. Their lives changed. Please record it.",
                    index: 0),
                block(id: "fallback", text: "A Xyzqwf appears.", index: 1),
            ],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            maxPhonemes: 35)

        let watchBlock = try #require(plan.blocks.first { $0.blockID == "watch" })
        #expect(watchBlock.synthesisChunks.count > 1)
        let decisions = Dictionary(
            uniqueKeysWithValues: watchBlock.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        let startable = try #require(decisions["startable"])
        #expect(startable.wordStart == 3)
        #expect(startable.wordEnd == 3)
        #expect(startable.source == .builtInOverride)
        #expect(startable.ruleID == "override.built-in.startable")

        let filesystem = try #require(decisions["filesystem"])
        #expect(filesystem.wordStart == 5)
        #expect(filesystem.wordEnd == 5)
        #expect(filesystem.source == .builtInOverride)
        #expect(filesystem.ruleID == "override.built-in.filesystem")

        let verified = try #require(decisions["verified"])
        #expect(verified.wordStart == 7)
        #expect(verified.wordEnd == 7)
        #expect(verified.source == .monitoredLexicon)
        #expect(verified.selectedIPA == "vˈɛɹəfˌId")
        #expect(
            verified.kokoroTokenIDs
                == (try PronunciationPlanner().phonemeIDs(forIPA: verified.selectedIPA)))
        #expect(verified.ruleID == "g2p.lexicon.verified")

        let live = try #require(decisions["live"])
        #expect(live.wordStart == 9)
        #expect(live.wordEnd == 9)
        #expect(live.source == .contextualHomograph)
        #expect(live.ruleID == "homograph.live.verb.preceder")

        let lives = try #require(decisions["lives"])
        #expect(lives.wordStart == 12)
        #expect(lives.wordEnd == 12)
        #expect(lives.source == .contextualHomograph)
        #expect(lives.ruleID == "homograph.lives.noun.preceder")

        let record = try #require(decisions["record"])
        #expect(record.wordStart == 15)
        #expect(record.wordEnd == 15)
        #expect(record.source == .contextualHomograph)
        #expect(record.ruleID == "homograph.record.verb.preceder")

        let fallbackBlock = try #require(plan.blocks.first { $0.blockID == "fallback" })
        let fallback = try #require(
            fallbackBlock.pronunciationDecisions.first {
                $0.normalizedWord == "xyzqwf"
            })
        #expect(fallback.wordStart == 1)
        #expect(fallback.wordEnd == 1)
        #expect(fallback.source == .fallback)
        #expect(fallback.selectedIPA == "zˈizkwf")
        #expect(fallback.ruleID == "g2p.fallback.xyzqwf")
        #expect(!fallback.kokoroTokenIDs.isEmpty)

        let keys = plan.blocks.flatMap(\.pronunciationDecisions).map {
            "\($0.blockID):\($0.wordStart):\($0.wordEnd)"
        }
        #expect(Set(keys).count == keys.count)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func watchVocabularyRemainsGlobalWhenABlockOmitsWatchedTerms() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "verified-only", text: "It was verified.", index: 0)],
            overrides: PronunciationOverrides(entries: [:]))

        #expect(
            plan.blocks.first?.pronunciationDecisions.map(\.normalizedWord)
                == ["verified"])
        #expect(
            PronunciationWatchVocabulary.words.isSuperset(
                of: Set(["startable", "filesystem", "verified", "live", "lives", "record"])))
    }

    @Test func mismatchedEvidenceRemainsAuditIncompleteAcrossPlanningBoundaries() throws {
        let planner = try PronunciationPlanner()
        let fallbackChunk = try planner.plan(
            displayText: "different",
            g2pInputText: "Xyzqwf")
        let lexiconChunk = try planner.plan(
            displayText: "another",
            g2pInputText: "verified")

        #expect(!fallbackChunk.phonemes.isEmpty)
        #expect(fallbackChunk.pronunciationTokenEvidence.isEmpty)
        #expect(
            fallbackChunk.pronunciationEvidenceValidation
                == .mismatch(
                    expectedDisplayText: "different",
                    reconstructedSpokenSurface: "Xyzqwf"))
        #expect(!fallbackChunk.pronunciationFallbackHits.isEmpty)

        let plannedBlock = NarrationPlannedBlock(
            blockID: "mismatch",
            originalBlock: block(id: "mismatch", text: "different", index: 0),
            synthesisChunks: [fallbackChunk, lexiconChunk],
            pronunciationDecisions: [],
            pronunciationDecisionDiagnostics: [],
            trailingSilence: nil)
        let renderPlan = NarrationRenderPlan(blocks: [plannedBlock])

        #expect(plannedBlock.pronunciationDecisions.isEmpty)
        #expect(plannedBlock.pronunciationAuditDiagnostics.count == 2)
        let fallbackDiagnostic = try #require(
            plannedBlock.pronunciationAuditDiagnostics.first)
        #expect(fallbackDiagnostic.reason == .spokenSurfaceMismatch)
        #expect(fallbackDiagnostic.blockID == "mismatch")
        #expect(fallbackDiagnostic.chunkIndex == 0)
        #expect(fallbackDiagnostic.expectedDisplayText == "different")
        #expect(fallbackDiagnostic.reconstructedSpokenSurface == "Xyzqwf")
        #expect(fallbackDiagnostic.fallbackHits == fallbackChunk.pronunciationFallbackHits)

        let noFallbackDiagnostic = plannedBlock.pronunciationAuditDiagnostics[1]
        #expect(noFallbackDiagnostic.chunkIndex == 1)
        #expect(noFallbackDiagnostic.fallbackHits.isEmpty)
        #expect(renderPlan.pronunciationAuditDiagnostics == plannedBlock.pronunciationAuditDiagnostics)

        let encoded = try JSONEncoder().encode(renderPlan.pronunciationAuditDiagnostics)
        #expect(
            try JSONDecoder().decode(
                [PronunciationAuditDiagnostic].self,
                from: encoded) == renderPlan.pronunciationAuditDiagnostics)
    }

    @Test func plansSpeechBlocksWithNormalizedOverrideText() throws {
        let blocks = [
            block(id: "b0", text: "Deploy Kubernetes — now.", index: 0)
        ]
        let overrides = PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: overrides,
            maxChars: 350)

        #expect(plan.blocks.count == 1)
        #expect(plan.blocks[0].blockID == "b0")
        #expect(
            plan.blocks[0].synthesisChunks.map(\.g2pInputText)
                == ["Deploy [Kubernetes](/kuːbərˈnɛtɪs/), now."])
        #expect(plan.blocks[0].trailingSilence == nil)
    }

    @Test func rawBlockOverloadResolvesCodeCueAndFallbackBeforePlanning() throws {
        var captioned = block(
            id: "captioned-code",
            text: "let value = answer + 42",
            kind: EPubBlockRecord.Kind.code.rawValue,
            index: 0)
        captioned.narrationText = "Example value assignment."
        var fallback = block(
            id: "fallback-code",
            text: "print(rawSyntaxMustNotBeSpoken)",
            kind: EPubBlockRecord.Kind.code.rawValue,
            index: 1)
        fallback.narrationText = "   "

        let plan = try NarrationRenderPlanner.make(
            blocks: [captioned, fallback],
            overrides: PronunciationOverrides(entries: ["example": "tˈɛst"]))
        let displayText = plan.blocks.flatMap(\.synthesisChunks).map(\.displayText)

        #expect(displayText == ["Example value assignment.", NarrationCodeBlockCue.fallback])
        #expect(!displayText.contains { $0.contains("answer") })
        #expect(!displayText.contains { $0.contains("rawSyntaxMustNotBeSpoken") })
        #expect(plan.blocks.allSatisfy { $0.pronunciationDecisions.isEmpty })
    }

    @Test func decorativeBlockBecomesSectionBreakSilenceOnly() throws {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "* * *", index: 1),
            block(id: "b2", text: "After.", index: 2),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks.map(\.blockID) == ["b0", "b1", "b2"])
        #expect(plan.blocks[0].synthesisChunks.map(\.displayText) == ["Before."])
        #expect(plan.blocks[0].trailingSilence == nil)
        #expect(plan.blocks[1].synthesisChunks.isEmpty)
        #expect(plan.blocks[1].trailingSilence == .sectionBreak)
        #expect(plan.blocks[2].synthesisChunks.map(\.displayText) == ["After."])
    }

    @Test func finalSpeakableBlockHasNoTrailingParagraphPause() throws {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "After.", index: 1),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .paragraph)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func headingGetsLongerPauseThanParagraph() throws {
        let blocks = [
            block(id: "h", text: "Chapter One", kind: "heading", index: 0),
            block(id: "p", text: "The first paragraph.", index: 1),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .heading)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func resolvesFullBlockBeforePlanningChunks() throws {
        let overrides = PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "They live by the filesystem.", index: 0)],
            overrides: overrides,
            maxPhonemes: 420
        )

        let chunk = try #require(plan.blocks.first?.synthesisChunks.first)
        #expect(chunk.displayText == "They live by the filesystem.")
        #expect(chunk.g2pInputText.contains("[live](/lˈɪv/)"))
        #expect(chunk.g2pInputText.contains("[filesystem](/fˈIl sˌɪstəm/)"))
        #expect(chunk.phonemeIDs.count > 2)
    }

    @Test func naturalContextHomographsReachPlannedTTS() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "lives",
                    text: "That gap is where this entire subject lives.",
                    index: 0),
                block(
                    id: "record",
                    text: "Listen and record whatever it says.",
                    index: 1),
            ],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420
        )

        let chunks = plan.blocks.flatMap(\.synthesisChunks)
        let g2pInputText = chunks.map(\.g2pInputText).joined(separator: " ")
        let phonemes = chunks.map(\.phonemes).joined(separator: " ")

        #expect(g2pInputText.contains("[lives](/lˈɪvz/)"))
        #expect(g2pInputText.contains("[record](/ɹəkˈɔɹd/)"))
        #expect(phonemes.contains("lˈɪvz"))
        #expect(phonemes.contains("ɹəkˈɔɹd"))
    }

    @Test func trailingMaterialLivesRuleReachesExactPreTTSPlanAndReceipt() throws {
        let source = "That gap is where this entire subject lives today."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "lives-today", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first { $0.normalizedWord == "lives" })
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: "lˈɪvz")

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "That gap is where this entire subject [lives](/lˈɪvz/) today.")
        #expect(chunk.phonemes.contains("lˈɪvz"))
        #expect(decision.selectedIPA == "lˈɪvz")
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .contextualHomograph)
        #expect(decision.ruleID == "homograph.lives.verb.subject")
    }

    @Test func descriptiveLivesNounRuleReachesExactPreTTSPlanAndReceipt() throws {
        let source = "This is one of the strangest lives in the story."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "lives-superlative", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first { $0.normalizedWord == "lives" })
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: "lˈIvz")

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "This is one of the strangest [lives](/lˈIvz/) in the story.")
        #expect(chunk.phonemes.contains("lˈIvz"))
        #expect(decision.selectedIPA == "lˈIvz")
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .contextualHomograph)
        #expect(decision.ruleID == "homograph.lives.noun.one-of-superlative")
    }

    @Test func superpositionLongUReachesExactPreTTSPlanAndReceipt() throws {
        let source = "Researchers call this superposition."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "superposition", text: source, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "superposition"
            })
        let expectedIPA = "sˌuːpɚpəzˈɪʃən"
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: expectedIPA)

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "Researchers call this [superposition](/sˌuːpɚpəzˈɪʃən/).")
        #expect(chunk.phonemes.contains(expectedIPA))
        #expect(decision.selectedIPA == expectedIPA)
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.superposition")
    }

    @Test func naturalContextFalsePositivesStayOutOfPlannedTTS() throws {
        let sourceText = [
            "Where should we meet? Lives changed.",
            "They remember where lives were lost.",
            "They remember where innocent lives were lost.",
            "They cited the world record, which still stands.",
        ]
        let plan = try NarrationRenderPlanner.make(
            blocks: sourceText.enumerated().map { index, text in
                block(id: "negative-\(index)", text: text, index: index)
            },
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420
        )

        let g2pInputText = plan.blocks
            .flatMap(\.synthesisChunks)
            .map(\.g2pInputText)

        #expect(g2pInputText == sourceText)
        #expect(!g2pInputText.contains { $0.contains("[lives](/lˈɪvz/)") })
        #expect(!g2pInputText.contains { $0.contains("[record](/ɹəkˈɔɹd/)") })
    }

    @Test func universalResolutionRunsAfterOverridesAndBeforeContextualHomographs() throws {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ"),
                "record": ("cmudict.record.fixture", "wrong"),
            ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "universal",
                    text: "Please record foobar and startable.",
                    index: 0)
            ],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: pack)

        let planned = try #require(plan.blocks.first)
        let resolved = planned.synthesisChunks.map(\.g2pInputText).joined(separator: " ")
        let decisions = Dictionary(
            uniqueKeysWithValues: planned.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        #expect(resolved.contains("[record](/ɹəkˈɔɹd/)"))
        #expect(resolved.contains("[foobar](/fˈubɑɹ/)"))
        #expect(resolved.contains("[startable](/stˈɑɹtəbəl/)"))
        #expect(decisions["record"]?.source == .contextualHomograph)
        #expect(decisions["foobar"]?.source == .supplementalLexicon)
        #expect(decisions["startable"]?.source == .derivedMorphology)
    }

    @Test func straightAndCurlyApostropheCandidatesMaterializeIdenticalAuditProvenance() throws {
        let candidateID = "cmudict.aujourd'hui.fixture"
        let packVersion =
            "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        let ipa = "oʒuɹdɥˈi"
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion: packVersion,
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "aujourd'hui": (candidateID, ipa)
            ])
        let authoredWords = ["aujourd'hui", "aujourd’hui"]
        let plan = try NarrationRenderPlanner.make(
            blocks: authoredWords.enumerated().map { index, word in
                block(id: "apostrophe-\(index)", text: "An \(word) example.", index: index)
            },
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: pack)

        #expect(plan.blocks.count == authoredWords.count)
        for (index, authoredWord) in authoredWords.enumerated() {
            let planned = plan.blocks[index]
            let chunk = try #require(planned.synthesisChunks.first)
            let decision = try #require(planned.pronunciationDecisions.first)

            #expect(planned.pronunciationDecisions.count == 1)
            #expect(planned.pronunciationDecisionDiagnostics.isEmpty)
            #expect(planned.pronunciationAuditDiagnostics.isEmpty)
            #expect(chunk.g2pInputText == "An [\(authoredWord)](/\(ipa)/) example.")
            #expect(chunk.phonemes.contains(ipa))
            #expect(decision.normalizedWord == "aujourd'hui")
            #expect(decision.sourceWord == authoredWord)
            #expect(decision.wordStart == 1)
            #expect(decision.wordEnd == 1)
            #expect(decision.selectedIPA == ipa)
            #expect(!decision.kokoroTokenIDs.isEmpty)
            #expect(decision.source == .supplementalLexicon)
            #expect(decision.candidateID == candidateID)
            #expect(decision.candidatePackVersion == packVersion)
        }
    }

    @Test func overrideWinsUniversalCandidateAndFirstSeedForSpanStaysFrozen() throws {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
            ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "override", text: "A foobar appeared.", index: 0)],
            overrides: PronunciationOverrides(
                entries: ["foobar": "fˈoʊbɑɹ"],
                source: .globalOverride),
            pronunciationPack: pack)

        let planned = try #require(plan.blocks.first)
        let decision = try #require(planned.pronunciationDecisions.first)
        #expect(planned.pronunciationDecisions.count == 1)
        #expect(decision.source == .globalOverride)
        #expect(decision.selectedIPA == "fˈoʊbɑɹ")
        #expect(
            planned.synthesisChunks.first?.g2pInputText
                == "A [foobar](/fˈoʊbɑɹ/) appeared.")
    }
}
