// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

// MARK: - GeneratedStudyDeckCardDraft + kind / clozeText

@Suite struct GeneratedStudyDeckDraftTests {

    // MARK: - Default init produces a basic card (backward-compat)

    @Test func defaultInitYieldsBasicKind() {
        let card = GeneratedStudyDeckCardDraft(
            id: "card-1",
            sourceBlockID: "block-1",
            frontText: "What is the powerhouse of the cell?",
            backText: "Mitochondria"
        )

        #expect(card.kind == .basic)
        #expect(card.clozeText == nil)
    }

    // MARK: - Basic cards: cloze logic does not affect them

    @Test func basicCardSurvivesValidationWithValidAnchorAndLength() throws {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "basic-1",
                    sourceBlockID: "block-a",
                    frontText: "What does ATP stand for?",
                    backText: "Adenosine triphosphate",
                    kind: .basic
                )
            ],
            validSourceBlockIDs: ["block-a"]
        )

        let card = try #require(draft.cards.first)
        #expect(draft.cards.count == 1)
        #expect(card.kind == .basic)
    }

    @Test func basicCardDroppedOnBadAnchor() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "basic-2",
                    sourceBlockID: "unknown-block",
                    frontText: "What does ATP stand for?",
                    backText: "Adenosine triphosphate",
                    kind: .basic
                )
            ],
            validSourceBlockIDs: ["block-a"]
        )

        #expect(draft.cards.isEmpty)
    }

    @Test func basicCardDroppedOnOversizedFront() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "basic-3",
                    sourceBlockID: "block-a",
                    frontText: String(repeating: "x", count: 161),
                    backText: "Fine",
                    kind: .basic
                )
            ],
            validSourceBlockIDs: ["block-a"]
        )

        #expect(draft.cards.isEmpty)
    }

    // MARK: - Cloze cards: valid marker survives

    @Test func clozeCardWithValidMarkerSurvives() throws {
        let clozeText = "The {{c1::mitochondria}} is the powerhouse of the cell."

        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-1",
                    sourceBlockID: "block-b",
                    frontText: "Fill in the blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: clozeText
                )
            ],
            validSourceBlockIDs: ["block-b"]
        )

        let card = try #require(draft.cards.first)
        #expect(draft.cards.count == 1)
        #expect(card.kind == .cloze)
        #expect(card.clozeText == clozeText)
    }

    @Test func clozeCardKindAndClozeTextArePreservedThroughValidation() throws {
        let clozeText = "{{c1::Photosynthesis}} converts sunlight into sugar."

        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-2",
                    sourceBlockID: "block-c",
                    frontText: "Complete the sentence.",
                    backText: "Answer: Photosynthesis.",
                    kind: .cloze,
                    clozeText: clozeText
                )
            ],
            validSourceBlockIDs: ["block-c"]
        )

        let card = try #require(draft.cards.first)
        #expect(card.id == "cloze-2")
        #expect(card.kind == .cloze)
        #expect(card.clozeText == clozeText)
    }

    // MARK: - Cloze cards: invalid / missing clozeText is dropped

    @Test func clozeCardWithNilClozeTextIsDropped() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-bad-1",
                    sourceBlockID: "block-d",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: nil
                )
            ],
            validSourceBlockIDs: ["block-d"]
        )

        #expect(draft.cards.isEmpty)
    }

    @Test func clozeCardWithNoC1MarkerIsDropped() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-bad-2",
                    sourceBlockID: "block-e",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: "No marker here at all."
                )
            ],
            validSourceBlockIDs: ["block-e"]
        )

        #expect(draft.cards.isEmpty)
    }

    @Test func clozeCardWithMalformedMarkerIsDropped() {
        // c2 only — missing c1 means studyDeckHasValidClozeMarkers returns false
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-bad-3",
                    sourceBlockID: "block-f",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: "The {{c2::mitochondria}} is missing c1."
                )
            ],
            validSourceBlockIDs: ["block-f"]
        )

        #expect(draft.cards.isEmpty)
    }

    @Test func clozeCardWithEmptyClozeTextIsDropped() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "cloze-bad-4",
                    sourceBlockID: "block-g",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: ""
                )
            ],
            validSourceBlockIDs: ["block-g"]
        )

        #expect(draft.cards.isEmpty)
    }

    // MARK: - Mixed batch: basic and cloze coexist correctly

    @Test func mixedBatchFiltersCorrectly() {
        let draft = GeneratedStudyDeckDraft(
            cards: [
                GeneratedStudyDeckCardDraft(
                    id: "basic-ok",
                    sourceBlockID: "block-h",
                    frontText: "What is ATP?",
                    backText: "Energy currency of the cell.",
                    kind: .basic
                ),
                GeneratedStudyDeckCardDraft(
                    id: "cloze-ok",
                    sourceBlockID: "block-h",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: "{{c1::ATP}} is the energy currency of the cell."
                ),
                GeneratedStudyDeckCardDraft(
                    id: "cloze-bad",
                    sourceBlockID: "block-h",
                    frontText: "Fill in blank.",
                    backText: "See cloze.",
                    kind: .cloze,
                    clozeText: "No valid marker."
                ),
            ],
            validSourceBlockIDs: ["block-h"]
        )

        #expect(draft.cards.count == 2)
        #expect(draft.cards.map(\.id) == ["basic-ok", "cloze-ok"])
    }
}
