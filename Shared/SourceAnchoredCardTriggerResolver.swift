// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum SourceAnchoredCardTriggerResolver {
    struct State: Equatable, Sendable {
        var triggeredCardIDs: Set<String>

        init(triggeredCardIDs: Set<String> = []) {
            self.triggeredCardIDs = triggeredCardIDs
        }
    }

    struct Result: Sendable {
        var cardsToTrigger: [Flashcard]
        var state: State
    }

    static func resolve(
        previousBlockID: String?,
        activeBlockID: String?,
        cards: [Flashcard],
        state: State
    ) -> Result {
        var nextState = state
        let eligibleCards = cards.filter { card in
            guard card.isEnabled,
                let sourceBlockID = card.sourceBlockID,
                !nextState.triggeredCardIDs.contains(card.id)
            else {
                return false
            }

            switch card.triggerTiming {
            case .manualOnly:
                return false
            case .beginning:
                return previousBlockID != activeBlockID && activeBlockID == sourceBlockID
            case .end:
                return previousBlockID != activeBlockID && previousBlockID == sourceBlockID
            }
        }

        eligibleCards.forEach { nextState.triggeredCardIDs.insert($0.id) }
        return Result(cardsToTrigger: eligibleCards, state: nextState)
    }
}
