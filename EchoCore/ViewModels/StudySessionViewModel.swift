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
    /// Cards whose audio could not be played by hands-free advance today.
    var needsAttentionCardIDs: Set<String> = []

    @ObservationIgnored private let db: DatabaseWriter
    @ObservationIgnored private let logger = Logger(category: "StudySessionViewModel")
    @ObservationIgnored private let updateReviewNotification: @MainActor (Int) -> Void
    @ObservationIgnored var onRequestAssignmentPlayback: ((Flashcard) -> Void)?
    @ObservationIgnored var onRetirePrompt: ((StudyChapterRetireService.RetirePrompt) -> Void)?

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
        updateReviewNotification: @escaping @MainActor (Int) -> Void = {
            ReviewNotificationService.updateNotification(dueCount: $0, isEnabled: false)
        }
    ) {
        self.db = db
        self.updateReviewNotification = updateReviewNotification
    }

    func loadQueue(
        now: Date = Date(),
        calendar: Calendar = .current,
        modeOverride: StudyPlanQueueMode? = nil,
        globalNewChapterLimit: Int? = nil,
        globalNewCardLimit: Int? = nil
    ) throws {
        let builder = StudyQueueBuilder(db: db)
        queue = try builder.build(
            now: now,
            calendar: calendar,
            modeOverride: modeOverride,
            globalNewChapterLimit: globalNewChapterLimit,
            globalNewCardLimit: globalNewCardLimit
        )
        currentIndex = 0
        isRevealed = false
        errorMessage = nil

        let newItemIDs = queue.entries
            .filter { $0.category == .newAssignment }
            .compactMap { $0.item?.id }
        try StudyPlanDAO(db: db).markIntroduced(itemIDs: newItemIDs, now: now)
        try releaseCurrentNewCardIfNeeded(now: now)
        needsAttentionCardIDs =
            (try? StudyPlaybackQueueService(db: db)
                .needsAttentionFlashcardIDs(now: now, calendar: calendar)) ?? []
        updateReviewNotification(remainingReviewNotificationCount())
        NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
    }

    func reveal() {
        isRevealed = true
    }

    func requestPlayCurrentAssignment() {
        guard let entry = currentEntry,
            entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
                || entry.flashcard.cardType == StudyFlashcardType.imageAssignment
                || entry.flashcard.cardType == StudyFlashcardType.vocabulary
        else {
            return
        }

        onRequestAssignmentPlayback?(entry.flashcard)
    }

    func gradeCurrent(_ grade: ReviewGrade, now: Date = Date()) {
        guard let entry = currentEntry else { return }

        do {
            try FlashcardDAO(db: db).grade(
                cardID: entry.flashcard.id, grade: grade.rawValue, now: now)
            logFlashcardReviewed(card: entry.flashcard, grade: grade.rawValue, now: now)
            ReviewPromptManager.shared.recordActivationEvent(.studyCardReviewed, now: now)
            advance(now: now)
            updateReviewNotification(remainingReviewNotificationCount())
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            logger.error(
                "Failed to grade card \(entry.flashcard.id): \(error.localizedDescription)")
        }
    }

    /// Skip is offered only for listening assignments whose chapter has no
    /// user-created cards.
    func currentEntryIsSkipEligible() -> Bool {
        guard let entry = currentEntry,
            entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
        else { return false }

        return (try? StudyPlaybackQueueService(db: db)
            .isSkipEligible(assignmentCardID: entry.flashcard.id)) ?? false
    }

    /// Retention-neutral skip: no FSRS grade, due tomorrow, logged.
    func skipCurrent(now: Date = Date()) {
        guard let entry = currentEntry,
            entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
        else { return }

        let queueService = StudyPlaybackQueueService(db: db)
        guard (try? queueService.isSkipEligible(assignmentCardID: entry.flashcard.id)) == true else {
            return
        }

        do {
            try queueService.markSkipped(flashcardID: entry.flashcard.id, now: now)
            advance(now: now)
            updateReviewNotification(remainingReviewNotificationCount())
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            logger.error(
                "Failed to skip card \(entry.flashcard.id): \(error.localizedDescription)")
        }
    }

    func advance(now: Date = Date()) {
        currentIndex += 1
        isRevealed = false
        do {
            try releaseCurrentNewCardIfNeeded(now: now)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to release AI card: \(error.localizedDescription)")
        }
    }

    private func releaseCurrentNewCardIfNeeded(now: Date) throws {
        guard queue.entries.indices.contains(currentIndex) else { return }
        let entry = queue.entries[currentIndex]
        guard entry.category == .newCard,
              let itemID = entry.item?.id else {
            return
        }

        try StudyPlanDAO(db: db).releaseCards(itemIDs: [itemID], now: now)
        if let audiobookID = entry.plan?.audiobookID,
           let chapterIndex = entry.item?.chapterIndex,
           let prompt = try StudyChapterRetireService(db: db).promptForDrainedChapter(
               audiobookID: audiobookID,
               chapterIndex: chapterIndex,
               now: now
           ) {
            onRetirePrompt?(prompt)
        }
        guard let refreshedCard = try db.read({ db in
            try Flashcard.fetchOne(db, key: entry.flashcard.id)
        }) else {
            return
        }
        queue.entries[currentIndex] = StudyQueueEntry(
            id: entry.id,
            category: entry.category,
            plan: entry.plan,
            item: entry.item,
            flashcard: refreshedCard
        )
    }

    private func logFlashcardReviewed(card: Flashcard, grade: Int, now: Date) {
        let dao = RealTimeEventDAO(db: db)
        do {
            let metadataJSON = try FlashcardReviewMetadata(card: card, grade: grade)
                .encodedJSONString()
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

    private func remainingReviewNotificationCount() -> Int {
        guard currentIndex < queue.entries.count else { return 0 }

        return queue.entries[currentIndex...].filter { entry in
            entry.category == .dueReview || entry.category == .inProgressAssignment
        }.count
    }
}
