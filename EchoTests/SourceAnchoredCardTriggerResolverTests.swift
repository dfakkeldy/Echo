// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite
struct SourceAnchoredCardTriggerResolverTests {
    @Test
    func beginningCardTriggersWhenEnteringItsBlock() {
        let card = makeCard(id: "c1", sourceBlockID: "b1", triggerTiming: .beginning)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b0",
            activeBlockID: "b1",
            cards: [card],
            state: .init()
        )

        #expect(result.cardsToTrigger.map(\.id) == ["c1"])
        #expect(result.state.triggeredCardIDs == ["c1"])
    }

    @Test
    func manualOnlyCardDoesNotAutoTrigger() {
        let card = makeCard(id: "c1", sourceBlockID: "b1", triggerTiming: .manualOnly)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b0",
            activeBlockID: "b1",
            cards: [card],
            state: .init()
        )

        #expect(result.cardsToTrigger.isEmpty)
        #expect(result.state.triggeredCardIDs.isEmpty)
    }

    @Test
    func endCardTriggersWhenLeavingItsBlock() {
        let card = makeCard(id: "c1", sourceBlockID: "b1", triggerTiming: .end)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b1",
            activeBlockID: "b2",
            cards: [card],
            state: .init()
        )

        #expect(result.cardsToTrigger.map(\.id) == ["c1"])
        #expect(result.state.triggeredCardIDs == ["c1"])
    }

    @Test
    func sameBlockTransitionDoesNotTriggerAgain() {
        let beginning = makeCard(id: "beginning", sourceBlockID: "b1", triggerTiming: .beginning)
        let end = makeCard(id: "end", sourceBlockID: "b1", triggerTiming: .end)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b1",
            activeBlockID: "b1",
            cards: [beginning, end],
            state: .init()
        )

        #expect(result.cardsToTrigger.isEmpty)
        #expect(result.state.triggeredCardIDs.isEmpty)
    }

    @Test
    func doesNotRepeatCardAlreadyTriggeredInSession() {
        let card = makeCard(id: "c1", sourceBlockID: "b1", triggerTiming: .beginning)
        let state = SourceAnchoredCardTriggerResolver.State(triggeredCardIDs: ["c1"])

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b0",
            activeBlockID: "b1",
            cards: [card],
            state: state
        )

        #expect(result.cardsToTrigger.isEmpty)
        #expect(result.state.triggeredCardIDs == ["c1"])
    }

    @Test
    func ignoresDisabledAndUnanchoredCards() {
        let disabled = makeCard(
            id: "disabled",
            sourceBlockID: "b1",
            triggerTiming: .beginning,
            isEnabled: false
        )
        let unanchored = makeCard(id: "unanchored", sourceBlockID: nil, triggerTiming: .beginning)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b0",
            activeBlockID: "b1",
            cards: [disabled, unanchored],
            state: .init()
        )

        #expect(result.cardsToTrigger.isEmpty)
        #expect(result.state.triggeredCardIDs.isEmpty)
    }

    @Test
    func preservesInputOrderForMultipleEligibleCards() {
        let first = makeCard(id: "c1", sourceBlockID: "b1", triggerTiming: .beginning)
        let second = makeCard(id: "c2", sourceBlockID: "b1", triggerTiming: .beginning)

        let result = SourceAnchoredCardTriggerResolver.resolve(
            previousBlockID: "b0",
            activeBlockID: "b1",
            cards: [second, first],
            state: .init()
        )

        #expect(result.cardsToTrigger.map(\.id) == ["c2", "c1"])
        #expect(result.state.triggeredCardIDs == ["c1", "c2"])
    }

    private func makeCard(
        id: String,
        sourceBlockID: String?,
        triggerTiming: FlashcardTriggerTiming,
        isEnabled: Bool = true
    ) -> Flashcard {
        Flashcard(
            id: id,
            audiobookID: "book",
            frontText: "Front \(id)",
            backText: "Back \(id)",
            mediaTimestamp: 0,
            endTimestamp: nil,
            triggerTiming: triggerTiming,
            nextReviewDate: nil,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: isEnabled,
            deckID: nil,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: sourceBlockID,
            playlistPosition: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
