// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

@testable import Echo

@MainActor
enum StudyCardFixtures {
    struct MissingPlanError: Error {}

    @discardableResult
    static func seedAcceptedCard(
        id: String,
        audiobookID: String = "book-a",
        chapterIndex: Int?,
        ordinal: Int,
        released: Bool = false,
        releasedAt: Date = StudyQueueFixtures.mondayNoon.addingTimeInterval(-3_600),
        isEnabled: Bool = true,
        in service: DatabaseService
    ) throws -> String {
        let planID = try service.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM study_plan WHERE audiobook_id = ?",
                arguments: [audiobookID]
            )
        }
        guard let planID else { throw MissingPlanError() }

        let stamp = StudyQueueFixtures.mondayNoon.ISO8601Format()
        let releasedStamp = releasedAt.ISO8601Format()
        try service.write { db in
            var card = Flashcard(
                id: id,
                audiobookID: audiobookID,
                frontText: "Card \(id)",
                backText: "Back",
                mediaTimestamp: 0,
                endTimestamp: nil,
                triggerTiming: .manualOnly,
                nextReviewDate: released ? releasedStamp : nil,
                intervalDays: 0,
                easeFactor: 2.5,
                repetitions: 0,
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: isEnabled,
                deckID: nil,
                tags: "auto study card",
                mediaJSON: nil,
                sourceBlockID: nil,
                playlistPosition: nil,
                createdAt: stamp,
                modifiedAt: stamp,
                stability: nil,
                difficulty: nil,
                cardType: StudyFlashcardType.normal,
                clozeIndex: nil
            )
            try card.insert(db)

            var item = StudyPlanItem(
                id: "item-\(id)",
                planID: planID,
                flashcardID: id,
                kind: StudyPlanItemKind.card.rawValue,
                chapterIndex: chapterIndex,
                sourceBlockID: nil,
                ordinal: ordinal,
                introducedAt: released ? releasedStamp : nil,
                isEnabled: isEnabled,
                createdAt: stamp,
                modifiedAt: stamp
            )
            try item.insert(db)
        }

        return "item-\(id)"
    }
}
