// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class StudySessionViewModel {
    var queue: StudyQueue = .empty
    var currentIndex: Int = 0
    var isRevealed: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudySessionViewModel")
    @ObservationIgnored private let updateReviewNotification: (Int) -> Void
    @ObservationIgnored var onRequestAssignmentPlayback: ((Flashcard) -> Void)?

    var currentEntry: StudyQueueEntry? {
        guard queue.entries.indices.contains(currentIndex) else { return nil }
        return queue.entries[currentIndex]
    }

    var progress: (current: Int, total: Int) {
        (min(currentIndex + 1, queue.entries.count), queue.entries.count)
    }

    var isComplete: Bool {
        currentIndex >= queue.entries.count
    }

    init(
        db: DatabaseWriter,
        updateReviewNotification: @escaping (Int) -> Void = {
            ReviewNotificationService.updateNotification(dueCount: $0)
        }
    ) {
        self.db = db
        self.updateReviewNotification = updateReviewNotification
    }

    func loadQueue(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil
    ) throws {
        let builder = StudyQueueBuilder(db: db)
        queue = try builder.build(now: now, calendar: calendar, modeOverride: modeOverride)
        currentIndex = 0
        isRevealed = false
        errorMessage = nil

        let newItemIDs = queue.entries
            .filter { $0.category == .newAssignment }
            .compactMap { $0.item?.id }
        try StudyPlanDAO(db: db).markIntroduced(itemIDs: newItemIDs, now: now)
        updateReviewNotification(queue.dueReviewCount + queue.inProgressAssignmentCount)
    }

    func reveal() {
        isRevealed = true
    }

    func requestPlayCurrentAssignment() {
        guard let entry = currentEntry,
              entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
                || entry.flashcard.cardType == StudyFlashcardType.imageAssignment else {
            return
        }

        onRequestAssignmentPlayback?(entry.flashcard)
    }

    func gradeCurrent(_ grade: ReviewGrade, now: Date = Date()) {
        guard let entry = currentEntry else { return }

        do {
            try FlashcardDAO(db: db).grade(cardID: entry.flashcard.id, grade: grade.rawValue, now: now)
            logFlashcardReviewed(card: entry.flashcard, grade: grade.rawValue, now: now)
            advance()
            updateReviewNotification(max(0, queue.entries.count - currentIndex))
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to grade card \(entry.flashcard.id): \(error.localizedDescription)")
        }
    }

    func advance() {
        currentIndex += 1
        isRevealed = false
    }

    private func logFlashcardReviewed(card: Flashcard, grade: Int, now: Date) {
        let dao = RealTimeEventDAO(db: db)
        do {
            let metadata = try JSONSerialization.data(withJSONObject: ["cardId": card.id, "grade": grade])
            let metadataJSON = String(data: metadata, encoding: .utf8)
            try dao.log(
                id: UUID().uuidString,
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: "Grade: \(grade)",
                metadataJSON: metadataJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
        } catch {
            logger.error("Failed to log flashcard review: \(error.localizedDescription)")
        }
    }
}
