// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// End-of-chapter checkpoint state machine owned by the player model on each
/// platform. Player side effects are injected through closures so the core
/// arming, grading, timeout, and skip rules stay testable without a player.
@MainActor @Observable
final class StudyCheckpointCoordinator {
    enum CheckpointAction {
        case good
        case again
        case skip
    }

    struct Context: Equatable, Sendable {
        let flashcardID: String
        let audiobookID: String
        let chapterIndex: Int
        let chapterTitle: String
        let skipEligible: Bool
        let sleepStopRequested: Bool
    }

    enum State: Equatable {
        case idle
        case checkpointActive(Context)
    }

    private(set) var state: State = .idle
    private(set) var remainingSeconds: Int = 0

    @ObservationIgnored var pausePlayback: (() -> Void)?
    @ObservationIgnored var isSleepStopRequested: (() -> Bool)?
    @ObservationIgnored var fireSleepStop: (() -> Void)?
    @ObservationIgnored var isPlayable: ((StudyPlayableItem) -> Bool)?
    @ObservationIgnored var onCheckpointActivated: ((Context) -> Void)?
    @ObservationIgnored var onCheckpointResolved: (() -> Void)?

    @ObservationIgnored private let database: DatabaseService
    @ObservationIgnored private let settingsProvider: () -> StudyCheckpointSettings
    @ObservationIgnored private let replayChapter: () -> Void
    @ObservationIgnored private let advance: (StudyPlayableItem) -> Void
    @ObservationIgnored private let announce: (String) -> Void

    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var countdownSuspended = false
    @ObservationIgnored private var deferredBoundary: DeferredBoundary?

    @ObservationIgnored private let logger = Logger(category: "StudyCheckpoint")

    init(
        database: DatabaseService,
        settingsProvider: @escaping () -> StudyCheckpointSettings,
        replayChapter: @escaping () -> Void,
        advance: @escaping (StudyPlayableItem) -> Void,
        announce: @escaping (String) -> Void
    ) {
        self.database = database
        self.settingsProvider = settingsProvider
        self.replayChapter = replayChapter
        self.advance = advance
        self.announce = announce
    }

    deinit {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
        }
    }

    @discardableResult
    func handleChapterEnd(audiobookID: String, chapterIndex: Int, naturalEnd: Bool) -> Bool {
        guard naturalEnd, case .idle = state else { return false }

        let boundary = DeferredBoundary(audiobookID: audiobookID, chapterIndex: chapterIndex)
        if deferredBoundary == boundary { return false }
        deferredBoundary = nil

        let assignment: StudyCheckpointAssignment?
        do {
            assignment = try StudyPlanDAO(db: database.writer).checkpointAssignment(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex
            )
        } catch {
            logger.error("Checkpoint lookup failed: \(error.localizedDescription)")
            return false
        }

        guard let assignment else { return false }

        let skipEligible =
            (try? StudyPlaybackQueueService(db: database.writer)
                .isSkipEligible(assignmentCardID: assignment.card.id)) ?? false

        pausePlayback?()
        let context = Context(
            flashcardID: assignment.card.id,
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            chapterTitle: assignment.card.frontText,
            skipEligible: skipEligible,
            sleepStopRequested: isSleepStopRequested?() ?? false
        )
        state = .checkpointActive(context)
        announce(String(localized: "Chapter finished. How did it go - good, or again?"))
        startCountdownIfNeeded()
        onCheckpointActivated?(context)
        return true
    }

    func resolve(_ action: CheckpointAction, now: Date = Date()) {
        guard case .checkpointActive(let context) = state else { return }
        if case .skip = action, !context.skipEligible {
            return
        }
        stopCountdown()

        switch action {
        case .good:
            grade(.good, context: context, auto: false, now: now)
            finish(context: context, replay: false)

        case .again:
            grade(.again, context: context, auto: false, now: now)
            finish(
                context: context,
                replay: settingsProvider().timeoutBehavior != .gradeAndAdvance
            )

        case .skip:
            do {
                try StudyPlaybackQueueService(db: database.writer)
                    .markSkipped(flashcardID: context.flashcardID, now: now)
            } catch {
                logger.error("Checkpoint skip failed: \(error.localizedDescription)")
            }
            finish(context: context, replay: false)
        }
    }

    func timeoutFired(now: Date = Date()) {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()

        switch settingsProvider().timeoutBehavior {
        case .replay:
            grade(.again, context: context, auto: true, now: now)
            finish(context: context, replay: true)

        case .gradeAndAdvance:
            grade(.again, context: context, auto: true, now: now)
            finish(context: context, replay: false)

        case .wait:
            deferBoundary(context: context)
        }
    }

    func cancel() {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()
        deferBoundary(context: context)
    }

    func suspendCountdown() {
        guard countdownTimer != nil, !countdownSuspended else { return }
        countdownSuspended = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func resumeCountdown() {
        guard case .checkpointActive = state, countdownSuspended else { return }
        countdownSuspended = false
        startTimer(seconds: max(1, remainingSeconds))
    }

    private func startCountdownIfNeeded() {
        let settings = settingsProvider()
        guard settings.timeoutBehavior != .wait else {
            remainingSeconds = 0
            return
        }

        startTimer(seconds: StudyCheckpointSettings.snappedTimeoutSeconds(settings.timeoutSeconds))
    }

    private func startTimer(seconds: Int) {
        countdownTimer?.invalidate()
        remainingSeconds = seconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
                if self.remainingSeconds <= 0 {
                    self.timeoutFired()
                }
            }
        }
        if let countdownTimer {
            RunLoop.main.add(countdownTimer, forMode: .common)
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSuspended = false
        remainingSeconds = 0
    }

    private func deferBoundary(context: Context) {
        deferredBoundary = DeferredBoundary(
            audiobookID: context.audiobookID,
            chapterIndex: context.chapterIndex
        )
        state = .idle
        onCheckpointResolved?()
    }

    private func grade(_ grade: ReviewGrade, context: Context, auto: Bool, now: Date) {
        do {
            guard let card = try database.read({
                try Flashcard.fetchOne($0, key: context.flashcardID)
            }) else {
                return
            }

            try FlashcardDAO(db: database.writer).grade(
                cardID: card.id,
                grade: grade.rawValue,
                now: now
            )

            let metadataJSON = try FlashcardReviewMetadata(
                card: card,
                grade: grade.rawValue,
                auto: auto ? true : nil
            ).encodedJSONString()
            try RealTimeEventDAO(db: database.writer).log(
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: card.frontText,
                subtitle: auto ? "Grade: \(grade.rawValue) (auto)" : "Grade: \(grade.rawValue)",
                metadataJSON: metadataJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
        } catch {
            logger.error("Checkpoint grade failed: \(error.localizedDescription)")
        }
    }

    private func finish(context: Context, replay: Bool) {
        state = .idle
        onCheckpointResolved?()
        defer {
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        }

        if context.sleepStopRequested {
            fireSleepStop?()
            return
        }

        if replay {
            deferredBoundary = nil
            replayChapter()
            return
        }

        guard settingsProvider().autoAdvance else { return }
        advanceToNextItem(after: context.flashcardID)
    }

    private func advanceToNextItem(after flashcardID: String) {
        let service = StudyPlaybackQueueService(db: database.writer)
        do {
            let step = try service.nextPlayableItem(
                after: flashcardID,
                globalNewChapterLimit: settingsProvider().globalNewChapterLimit,
                isPlayable: { isPlayable?($0) ?? true }
            )

            for unplayable in step.skippedUnplayable {
                try? service.markNeedsAttention(
                    item: unplayable,
                    reason: String(localized: "Couldn't play this chapter - check it in the study session.")
                )
                announce(
                    String(localized: "Skipping \(unplayable.title) - it can't play right now."))
            }

            if let next = step.next {
                deferredBoundary = nil
                if let itemID = next.planItemID {
                    try? StudyPlanDAO(db: database.writer).markIntroduced(itemIDs: [itemID])
                }
                advance(next)
            } else {
                announce(String(localized: "That's the end of today's study queue. Nice work."))
            }
        } catch {
            logger.error("Checkpoint advance failed: \(error.localizedDescription)")
        }
    }

    private struct DeferredBoundary: Equatable {
        let audiobookID: String
        let chapterIndex: Int
    }
}
