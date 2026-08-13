// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Builds a vocabulary `Flashcard` from a tapped word + its audio anchor.
/// Pure (caller supplies `id`/`createdAt`) so it is deterministically testable.
/// `backText` is intentionally empty — no public API returns the definition;
/// Look Up surfaces it on demand. The sentence context is stored in `mediaJSON`.
enum VocabularyCardBuilder {
    static func make(
        id: String, audiobookID: String, word: String, contextSentence: String?,
        blockID: String?, audioStart: TimeInterval, audioEnd: TimeInterval?, createdAt: String
    ) -> Flashcard {
        var mediaJSON: String?
        if let contextSentence, !contextSentence.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: ["context": contextSentence]),
            let json = String(data: data, encoding: .utf8)
        {
            mediaJSON = json
        }
        var card = Flashcard(
            id: id, audiobookID: audiobookID, frontText: word, backText: "",
            mediaTimestamp: audioStart, endTimestamp: audioEnd, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: 0, easeFactor: 2.5, repetitions: 0,
            lastReviewedAt: nil, lastGrade: nil, isEnabled: true, deckID: nil, tags: nil,
            mediaJSON: mediaJSON, sourceBlockID: blockID, playlistPosition: nil,
            createdAt: createdAt, modifiedAt: createdAt,
            stability: nil, difficulty: nil, cardType: "normal", clozeIndex: nil)
        card.cardType = StudyFlashcardType.vocabulary
        return card
    }
}
