// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
private final class QuizHarness {
    let service: DatabaseService
    var settings = StudyCheckpointSettings(
        timeoutSeconds: 30,
        timeoutBehavior: .replay,
        autoAdvance: true,
        remoteGrading: true,
        globalNewChapterLimit: 12,
        globalNewCardLimit: 20
    )
    var advanced: [StudyPlayableItem] = []
    var announcements: [String] = []
    var replayCount = 0
    private(set) var coordinator: StudyCheckpointCoordinator!

    init(service: DatabaseService) {
        self.service = service
        coordinator = StudyCheckpointCoordinator(
            database: service,
            settingsProvider: { [weak self] in
                self?.settings
                    ?? StudyCheckpointSettings(
                        timeoutSeconds: 30,
                        timeoutBehavior: .replay,
                        autoAdvance: true,
                        remoteGrading: true
                    )
            },
            replayChapter: { [weak self] in self?.replayCount += 1 },
            advance: { [weak self] item in self?.advanced.append(item) },
            announce: { [weak self] line in self?.announcements.append(line) }
        )
        coordinator.pausePlayback = {}
    }
}

@MainActor
@Suite struct StudyCheckpointQuizTests {
    @Test func screenOnTapReleasesPendingCardsAndStartsQuiz() throws {
        let h = try harness(pendingCardCount: 2, releasedCardCount: 0)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        guard case .quizActive(let quiz) = h.coordinator.state else {
            Issue.record("Expected active quiz")
            return
        }
        #expect(quiz.chapterIndex == 0)
        #expect(h.coordinator.quizCards.map(\.id) == ["pending-0", "pending-1"])
        #expect(h.advanced.isEmpty)
        #expect(try card(id: "pending-0", in: h.service).nextReviewDate == StudyQueueFixtures.mondayNoon.ISO8601Format())
    }

    @Test func screenOffSkipsQuizAnnouncesPendingAndReleasedCountWithoutRelease() throws {
        let h = try harness(pendingCardCount: 2, releasedCardCount: 1)
        h.coordinator.isScreenOn = { false }
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.coordinator.state == .idle)
        #expect(h.announcements.contains("3 cards waiting for review."))
        #expect(h.advanced.isEmpty)
        #expect(try card(id: "pending-0", in: h.service).nextReviewDate == nil)
    }

    @Test func gradingThroughQuizWritesGradesThenAdvances() throws {
        let h = try harness(pendingCardCount: 0, releasedCardCount: 2)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        h.coordinator.gradeQuizCard(.good, now: StudyQueueFixtures.mondayNoon)
        #expect(h.coordinator.currentQuizCard?.id == "released-1")
        h.coordinator.gradeQuizCard(.easy, now: StudyQueueFixtures.mondayNoon)

        #expect(try card(id: "released-0", in: h.service).lastGrade == ReviewGrade.good.rawValue)
        #expect(try card(id: "released-1", in: h.service).lastGrade == ReviewGrade.easy.rawValue)
        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func dismissLeavesRemainingQuizCardsDueAndRunsFinish() throws {
        let h = try harness(pendingCardCount: 0, releasedCardCount: 2)
        h.coordinator.handleChapterEnd(audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        h.coordinator.gradeQuizCard(.again, now: StudyQueueFixtures.mondayNoon)
        h.coordinator.dismissQuiz()

        let abandoned = try card(id: "released-1", in: h.service)
        #expect(abandoned.lastGrade == nil)
        #expect(abandoned.repetitions == 0)
        #expect(abandoned.nextReviewDate != nil)
        #expect(h.advanced.count == 1)
    }

    @Test func skipAndTimeoutNeverStartQuiz() throws {
        let skipped = try harness(pendingCardCount: 0, releasedCardCount: 2)
        skipped.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        skipped.coordinator.resolve(.skip, now: StudyQueueFixtures.mondayNoon)
        #expect(skipped.coordinator.quizCards.isEmpty)

        let timedOut = try harness(pendingCardCount: 0, releasedCardCount: 2)
        timedOut.coordinator.handleChapterEnd(
            audiobookID: "book-a", chapterIndex: 0, naturalEnd: true)
        timedOut.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)
        #expect(timedOut.coordinator.quizCards.isEmpty)
        #expect(timedOut.replayCount == 1)
    }

    private func harness(
        pendingCardCount: Int,
        releasedCardCount: Int
    ) throws -> QuizHarness {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for index in 0..<pendingCardCount {
            try StudyCardFixtures.seedAcceptedCard(
                id: "pending-\(index)",
                chapterIndex: 0,
                ordinal: 100 + index,
                in: service
            )
        }
        for index in 0..<releasedCardCount {
            try StudyCardFixtures.seedAcceptedCard(
                id: "released-\(index)",
                chapterIndex: 0,
                ordinal: 200 + index,
                released: true,
                in: service
            )
        }
        return QuizHarness(service: service)
    }

    private func card(id: String, in service: DatabaseService) throws -> Flashcard {
        try #require(try service.read { db in try Flashcard.fetchOne(db, key: id) })
    }
}
