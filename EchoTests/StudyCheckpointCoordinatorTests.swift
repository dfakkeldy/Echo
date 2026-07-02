// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Closure-capture harness in the SleepTimerManager ownership style: the
/// coordinator is built with recording closures so every player side effect
/// is observable without a player.
@MainActor
private final class CheckpointHarness {
    let service: DatabaseService
    var settings = StudyCheckpointSettings(
        timeoutSeconds: 30,
        timeoutBehavior: .replay,
        autoAdvance: true,
        remoteGrading: true
    )
    var pauseCount = 0
    var replayCount = 0
    var advanced: [StudyPlayableItem] = []
    var announcements: [String] = []
    var sleepArmed = false
    var sleepFired = 0
    var playableIDs: Set<String>?
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
            announce: { [weak self] cue in self?.announcements.append(cue) }
        )
        coordinator.pausePlayback = { [weak self] in self?.pauseCount += 1 }
        coordinator.isSleepStopRequested = { [weak self] in self?.sleepArmed ?? false }
        coordinator.fireSleepStop = { [weak self] in self?.sleepFired += 1 }
        coordinator.isPlayable = { [weak self] item in
            self?.playableIDs.map { $0.contains(item.flashcardID) } ?? true
        }
    }
}

@MainActor
struct StudyCheckpointCoordinatorTests {
    private func harness() throws -> CheckpointHarness {
        CheckpointHarness(
            service: try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress())
    }

    private func chapterOneCard(
        in service: DatabaseService,
        book: String = "Book A"
    ) throws -> Flashcard {
        let id = try #require(
            try service.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM flashcard WHERE front_text = ?",
                    arguments: ["\(book) Chapter 1"]
                )
            })
        return try #require(try service.read { db in try Flashcard.fetchOne(db, key: id) })
    }

    @Test func seekAcrossTheBoundaryDoesNotArm() throws {
        let h = try harness()
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: false
        )
        #expect(claimed == false)
        #expect(h.coordinator.state == .idle)
        #expect(h.pauseCount == 0)
    }

    @Test func nonDueChapterDoesNotArm() throws {
        let h = try harness()
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 2,
            naturalEnd: true
        )
        #expect(claimed == false)
        #expect(h.coordinator.state == .idle)
    }

    @Test func naturalEndOfDueChapterArmsPausesAndAnnounces() throws {
        let h = try harness()
        let claimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        #expect(claimed == true)
        #expect(h.pauseCount == 1)
        #expect(h.announcements.count == 1)
        guard case .checkpointActive(let context) = h.coordinator.state else {
            Issue.record("Expected active checkpoint")
            return
        }
        #expect(context.chapterTitle == "Book A Chapter 1")
        #expect(context.skipEligible == true)
        #expect(h.coordinator.remainingSeconds == 30)
    }

    @Test func waitBehaviorRunsNoCountdown() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .wait
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        #expect(h.coordinator.remainingSeconds == 0)
    }

    @Test func goodGradesAndAdvancesCrossQueue() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 3)
        #expect(graded.repetitions == 1)
        #expect(h.coordinator.state == .idle)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func goodWithAutoAdvanceOffStaysPut() throws {
        let h = try harness()
        h.settings.autoAdvance = false
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.advanced.isEmpty)
        #expect(h.coordinator.state == .idle)
    }

    @Test func sleepStopIsHonoredAfterTheGradeAndSuppressesAdvance() throws {
        let h = try harness()
        h.sleepArmed = true
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.sleepFired == 1)
        #expect(h.advanced.isEmpty)
        #expect(h.replayCount == 0)
    }

    @Test func sleepStopSuppressesTheAgainReplay() throws {
        let h = try harness()
        h.sleepArmed = true
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 1)
        #expect(h.sleepFired == 1)
        #expect(h.replayCount == 0)
    }

    @Test func tappedAgainReplaysUnderReplayAndWaitBehaviors() throws {
        for behavior in [CheckpointTimeoutBehavior.replay, .wait] {
            let h = try harness()
            h.settings.timeoutBehavior = behavior
            h.coordinator.handleChapterEnd(
                audiobookID: "book-a",
                chapterIndex: 0,
                naturalEnd: true
            )
            h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)
            #expect(h.replayCount == 1)
            #expect(h.advanced.isEmpty)
        }
    }

    @Test func tappedAgainAdvancesUnderGradeAndAdvance() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .gradeAndAdvance
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.again, now: StudyQueueFixtures.mondayNoon)

        #expect(h.replayCount == 0)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func timeoutReplayGradesAgainWithTheAutoFlag() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)

        let graded = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(graded.lastGrade == 1)
        #expect(h.replayCount == 1)

        let metadataJSON = try h.service.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT metadata_json FROM real_time_event
                    WHERE event_type = 'flashcard_reviewed' AND source_item_id = ?
                    """,
                arguments: [card.id]
            )
        }
        let metadata = FlashcardReviewMetadata.decode(metadataJSON)
        #expect(metadata?.auto == true)
    }

    @Test func tappedGradesCarryNoAutoFlag() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        let metadataJSON = try h.service.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT metadata_json FROM real_time_event
                    WHERE event_type = 'flashcard_reviewed' AND source_item_id = ?
                    """,
                arguments: [card.id]
            )
        }
        #expect(FlashcardReviewMetadata.decode(metadataJSON)?.auto == nil)
    }

    @Test func timeoutWaitRecordsNoGradeAndDefersTheBoundary() throws {
        let h = try harness()
        h.settings.timeoutBehavior = .wait
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.timeoutFired(now: StudyQueueFixtures.mondayNoon)

        let untouched = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(untouched.lastGrade == nil)
        #expect(h.coordinator.state == .idle)

        let reclaimed = h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        #expect(reclaimed == false)
    }

    @Test func cancelDefersLikeWaitTimeout() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        h.coordinator.cancel()
        #expect(h.coordinator.state == .idle)
        #expect(
            h.coordinator.handleChapterEnd(
                audiobookID: "book-a",
                chapterIndex: 0,
                naturalEnd: true
            ) == false)
    }

    @Test func skipWritesNoGradeAndAdvances() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.skip, now: StudyQueueFixtures.mondayNoon)

        let skipped = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(skipped.lastGrade == nil)
        #expect(skipped.nextReviewDate != nil)
        #expect(h.advanced.map(\.title) == ["Book A Chapter 2"])
    }

    @Test func ineligibleSkipIsIgnored() throws {
        let h = try harness()
        let card = try chapterOneCard(in: h.service)
        try StudyQueueFixtures.seedDueCard(
            id: "user-card-inside-chapter",
            audiobookID: "book-a",
            frontText: "My note",
            nextReviewDate: StudyQueueFixtures.mondayNoon,
            isEnabled: true,
            in: h.service
        )
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        guard case .checkpointActive(let context) = h.coordinator.state else {
            Issue.record("Expected active checkpoint")
            return
        }
        #expect(context.skipEligible == false)

        h.coordinator.resolve(.skip, now: StudyQueueFixtures.mondayNoon)

        let unchanged = try #require(
            try h.service.read { db in try Flashcard.fetchOne(db, key: card.id) })
        #expect(unchanged.lastGrade == nil)
        #expect(unchanged.nextReviewDate == nil)
        #expect(h.advanced.isEmpty)
        guard case .checkpointActive = h.coordinator.state else {
            Issue.record("Ineligible skip should leave the checkpoint active")
            return
        }
    }

    @Test func unplayableNextItemsAreAnnouncedAndFlagged() throws {
        let h = try harness()
        let bookACh2 = try chapterOneCard(in: h.service)
        let bookBCard = try chapterOneCard(in: h.service, book: "Book B")
        h.playableIDs = [bookBCard.id]
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )

        h.coordinator.resolve(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(h.advanced.map(\.audiobookID) == ["book-b"])
        #expect(h.announcements.count >= 2)
        let flagged = try StudyPlaybackQueueService(db: h.service.writer)
            .needsAttentionFlashcardIDs(
                now: Date(),
                calendar: StudyQueueFixtures.calendar
            )
        #expect(!flagged.isEmpty)
        _ = bookACh2
    }

    @Test func countdownSuspendAndResumeSurviveAnInterruption() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        #expect(h.coordinator.remainingSeconds == 30)

        h.coordinator.suspendCountdown()
        #expect(h.coordinator.remainingSeconds == 30)

        h.coordinator.resumeCountdown()
        #expect(h.coordinator.remainingSeconds == 30)
        guard case .checkpointActive = h.coordinator.state else {
            Issue.record("Checkpoint should survive an interruption")
            return
        }
    }

    @Test func aSecondBoundaryWhileActiveIsIgnored() throws {
        let h = try harness()
        h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        let second = h.coordinator.handleChapterEnd(
            audiobookID: "book-a",
            chapterIndex: 0,
            naturalEnd: true
        )
        #expect(second == false)
        #expect(h.pauseCount == 1)
    }
}
