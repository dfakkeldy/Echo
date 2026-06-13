import Foundation
import Observation
import GRDB
import os.log

@MainActor
@Observable
final class DailyReviewViewModel {
    var dueCards: [Flashcard] = []
    var currentIndex: Int = 0
    var isRevealed: Bool = false
    var isPlayingSnippet: Bool = false

    private let db: DatabaseWriter
    private let folderURL: URL?
    private let logger = Logger(category: "DailyReviewViewModel")

    @ObservationIgnored var snippetPlayer: SnippetPlayer?
    @ObservationIgnored var onRequestSnippetPlay: ((URL, TimeInterval, TimeInterval) -> Void)?

    var currentCard: Flashcard? {
        guard dueCards.indices.contains(currentIndex) else { return nil }
        return dueCards[currentIndex]
    }

    var progress: (current: Int, total: Int) {
        (min(currentIndex + 1, dueCards.count), dueCards.count)
    }

    var isComplete: Bool {
        currentIndex >= dueCards.count
    }

    init(db: DatabaseWriter, folderURL: URL?, snippetPlayer: SnippetPlayer? = nil) {
        self.db = db
        self.folderURL = folderURL
        self.snippetPlayer = snippetPlayer
    }

    func loadDueCards() {
        do {
            let dao = FlashcardDAO(db: db)
            dueCards = try dao.allDueCards()
            currentIndex = 0
            isRevealed = false
            ReviewNotificationService.updateNotification(dueCount: dueCards.count)
        } catch {
            logger.error("Failed to load due cards: \(error.localizedDescription)")
            dueCards = []
        }
    }

    func reveal() {
        isRevealed = true
        guard let card = currentCard,
              let end = card.endTimestamp,
              end > card.mediaTimestamp,
              let url = constructSourceURL(for: card.audiobookID) else { return }
        isPlayingSnippet = true
        onRequestSnippetPlay?(url, card.mediaTimestamp, end)
    }

    func gradeCard(_ grade: Int) {
        guard let card = currentCard else { return }
        snippetPlayer?.stop()
        isPlayingSnippet = false
        do {
            let dao = FlashcardDAO(db: db)
            let scheduler: any SchedulingAlgorithm = card.repetitions >= 6
                ? FSRSScheduler()
                : SM2Scheduler()
            try dao.grade(cardID: card.id, grade: grade, scheduler: scheduler)
            logFlashcardReviewed(card: card, grade: grade)
            let remaining = dueCards.count - (currentIndex + 1)
            ReviewNotificationService.updateNotification(dueCount: remaining)
        } catch {
            logger.error("Failed to grade card \(card.id): \(error.localizedDescription)")
        }
        advance()
    }

    func advance() {
        snippetPlayer?.stop()
        isPlayingSnippet = false
        currentIndex += 1
        isRevealed = false
    }

    private func constructSourceURL(for audiobookID: String) -> URL? {
        guard let folder = folderURL else { return nil }
        return URL(fileURLWithPath: audiobookID, relativeTo: folder)
    }

    private func logFlashcardReviewed(card: Flashcard, grade: Int) {
        let dao = RealTimeEventDAO(db: db)
        do {
            let meta = try JSONSerialization.data(withJSONObject: ["cardId": card.id, "grade": grade])
            let metaJSON = String(data: meta, encoding: .utf8)
            let now = Date()
            try dao.log(
                id: UUID().uuidString,
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: "Grade: \(grade)",
                metadataJSON: metaJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
        } catch {
            logger.error("Failed to log flashcard review: \(error.localizedDescription)")
        }
    }
}
