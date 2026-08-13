// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Compatibility wrapper that creates a generated study plan for a book's
/// chapter headings.
struct ChapterCardDrafter {
    /// Auto-draft chapter study assignments for a book. Returns the number of cards created.
    func draftCards(
        for audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter
    ) async throws -> Int {
        let generator = StudyPlanGenerator(db: db)
        let preview = try generator.preview(
            audiobookID: audiobookID,
            bookTitle: bookTitle,
            includeImages: false
        )
        guard !preview.candidates.isEmpty else { return 0 }

        let dao = StudyPlanDAO(db: db)
        if try dao.plan(for: audiobookID) != nil {
            return 0
        }

        let now = Date()
        let result = try dao.createPlan(
            StudyPlanCreationRequest(
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                cadenceUnit: .day,
                newChapterLimit: 1,
                includeImages: false,
                queueMode: .bookByBook,
                catchUpPolicy: .gentle,
                startDate: now,
                candidates: preview.candidates,
                now: now
            )
        )

        return result.createdCards.count
    }
}
