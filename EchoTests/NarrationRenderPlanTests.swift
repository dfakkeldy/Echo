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

    @Test func plannedDecisionIsPortableCodableAndContainsIPAOnlyIDs() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "The process is startable.", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: decision.selectedIPA)

        #expect(decision.blockID == "b0")
        #expect(decision.wordStart == 3)
        #expect(decision.wordEnd == 3)
        #expect(decision.normalizedWord == "startable")
        #expect(decision.sourceWord == "startable")
        #expect(decision.sourceContext == "The process is startable.")
        #expect(decision.selectedIPA == "stˈɑɹɾəbᵊl")
        #expect(decision.kokoroTokenIDs == expectedIDs)
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
}
