// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct FixtureStudyDeckGeneratorTests {
    private let generator = FixtureStudyDeckGenerator()

    @Test func emptySourcesProduceNoCards() {
        let draft = generator.generate(sources: [])

        #expect(draft.cards.isEmpty)
    }

    @Test func cardsPreserveSourceOrderAndSourceBlockIDs() {
        let sources = [
            source("block-1", text: "Alpha systems organize memory cues."),
            source("block-2", text: "Beta practice strengthens recall.", sequenceIndex: 1),
            source("block-3", text: "Gamma review connects related ideas.", sequenceIndex: 2),
        ]

        let draft = generator.generate(sources: sources)

        #expect(draft.cards.map(\.sourceBlockID) == ["block-1", "block-2", "block-3"])
        #expect(draft.cards.map(\.id) == ["fixture-block-1", "fixture-block-2", "fixture-block-3"])
    }

    @Test func respectsMaximumCardLimit() {
        let sources = (0..<5).map { index in
            source("block-\(index)", text: "Concept \(index) adds a useful retrieval cue.", sequenceIndex: index)
        }

        let draft = generator.generate(
            sources: sources,
            settings: StudyDeckGenerationSettings(maximumCardCount: 2)
        )

        #expect(draft.cards.map(\.sourceBlockID) == ["block-0", "block-1"])
    }

    @Test func validationFiltersBlankTextLongTextAndUnknownSources() throws {
        let longBack = String(repeating: "expanded detail ", count: 30)
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: " valid-card ",
                    sourceBlockID: " source-1 ",
                    frontText: "  What matters here?  ",
                    backText: "  A compact answer.  ",
                    tags: ["generated", " fixture ", "", "generated"]
                ),
                GeneratedStudyDeckCardDraft(
                    id: "   ",
                    sourceBlockID: "source-1",
                    frontText: "What matters here?",
                    backText: "A compact answer."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "blank-front",
                    sourceBlockID: "source-1",
                    frontText: "   ",
                    backText: "A compact answer."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "blank-back",
                    sourceBlockID: "source-1",
                    frontText: "What matters here?",
                    backText: "\n"
                ),
                GeneratedStudyDeckCardDraft(
                    id: "blank-source",
                    sourceBlockID: " ",
                    frontText: "What matters here?",
                    backText: "A compact answer."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "unknown-source",
                    sourceBlockID: "missing-source",
                    frontText: "What matters here?",
                    backText: "A compact answer."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "long-front",
                    sourceBlockID: "source-1",
                    frontText: String(repeating: "expanded front ", count: 20),
                    backText: "A compact answer."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "long-back",
                    sourceBlockID: "source-1",
                    frontText: "What matters here?",
                    backText: longBack
                ),
            ],
            validSourceBlockIDs: ["source-1"]
        )

        let card = try #require(draft.cards.first)
        #expect(draft.cards.count == 1)
        #expect(card.id == "valid-card")
        #expect(card.sourceBlockID == "source-1")
        #expect(card.frontText == "What matters here?")
        #expect(card.backText == "A compact answer.")
        #expect(card.tags == ["generated", "fixture"])
    }

    @Test func backsUseCompactKeywordSummariesInsteadOfLongSourcePassages() throws {
        let sourceText = """
            Mitochondria transform nutrients into cellular energy through a deliberately staged synthetic passage. \
            This paragraph adds many extra words so generated backs must avoid copying the source sentence wholesale.
            """

        let draft = generator.generate(sources: [
            source("bio-1", text: sourceText, chapterIndex: 2, blockIndex: 7)
        ])
        let card = try #require(draft.cards.first)

        #expect(card.sourceBlockID == "bio-1")
        #expect(card.backText.hasPrefix("Keywords:"))
        #expect(card.backText.contains("mitochondria"))
        #expect(card.backText.contains("Source: chapter 3, paragraph block 7."))
        #expect(card.backText.count < 120)
        #expect(!card.backText.contains(sourceText))
        #expect(!card.backText.contains("deliberately staged synthetic passage"))
    }

    private func source(
        _ sourceBlockID: String,
        text: String,
        chapterIndex: Int? = 0,
        blockKind: String = "paragraph",
        sequenceIndex: Int = 0,
        spineIndex: Int = 1,
        blockIndex: Int = 0
    ) -> StudyDeckSource {
        StudyDeckSource(
            id: sourceBlockID,
            sourceBlockID: sourceBlockID,
            audiobookID: "synthetic-book",
            blockKind: blockKind,
            text: text,
            chapterIndex: chapterIndex,
            sequenceIndex: sequenceIndex,
            spineIndex: spineIndex,
            blockIndex: blockIndex
        )
    }
}
