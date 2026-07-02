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

    struct QuizContext: Equatable, Sendable {
        let audiobookID: String
        let chapterIndex: Int
        let chapterTitle: String
    }

    enum State: Equatable {
        case idle
        case checkpointActive(Context)
        case quizActive(QuizContext)
    }

    private(set) var state: State = .idle
    private(set) var remainingSeconds: Int = 0
    static let quizCardCap = 5
    private(set) var quizCards: [Flashcard] = []
    private(set) var quizPosition: Int = 0

    var currentQuizCard: Flashcard? {
        quizCards.indices.contains(quizPosition) ? quizCards[quizPosition] : nil
    }

    @ObservationIgnored var pausePlayback: (() -> Void)?
    @ObservationIgnored var isSleepStopRequested: (() -> Bool)?
    @ObservationIgnored var fireSleepStop: (() -> Void)?
    @ObservationIgnored var isPlayable: ((StudyPlayableItem) -> Bool)?
    @ObservationIgnored var isScreenOn: (() -> Bool)?
    @ObservationIgnored var onCheckpointActivated: ((Context) -> Void)?
    @ObservationIgnored var onCheckpointResolved: (() -> Void)?
    @ObservationIgnored var onRetirePrompt: ((StudyChapterRetireService.RetirePrompt) -> Void)?

    @ObservationIgnored private let database: DatabaseService
    @ObservationIgnored private let settingsProvider: () -> StudyCheckpointSettings
    @ObservationIgnored private let replayChapter: () -> Void
    @ObservationIgnored private let advance: (StudyPlayableItem) -> Void
    @ObservationIgnored private let announce: (String) -> Void

    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var countdownSuspended = false
    @ObservationIgnored private var deferredBoundary: DeferredBoundary?
    @ObservationIgnored private var pendingFinish: PendingFinish?
    @ObservationIgnored private var pendingRetirePrompt: StudyChapterRetireService.RetirePrompt?

    @ObservationIgnored private let logger = Logger(category: "StudyCheckpoint")

    private enum PersistenceError: LocalizedError {
        case flashcardMissing(String)

        var errorDescription: String? {
            switch self {
            case .flashcardMissing(let id):
                "Missing flashcard for checkpoint: \(id)"
            }
        }
    }

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
            do {
                try grade(.good, context: context, auto: false, now: now)
                finishOrStartQuiz(context: context, replay: false, now: now)
            } catch {
                logger.error("Checkpoint grade failed: \(error.localizedDescription)")
            }

        case .again:
            do {
                try grade(.again, context: context, auto: false, now: now)
                finishOrStartQuiz(
                    context: context,
                    replay: settingsProvider().timeoutBehavior != .gradeAndAdvance,
                    now: now
                )
            } catch {
                logger.error("Checkpoint grade failed: \(error.localizedDescription)")
            }

        case .skip:
            do {
                try StudyPlaybackQueueService(db: database.writer)
                    .markSkipped(flashcardID: context.flashcardID, now: now)
                finish(context: context, replay: false)
            } catch {
                logger.error("Checkpoint skip failed: \(error.localizedDescription)")
            }
        }
    }

    func timeoutFired(now: Date = Date()) {
        guard case .checkpointActive(let context) = state else { return }
        stopCountdown()

        switch settingsProvider().timeoutBehavior {
        case .replay:
            do {
                try grade(.again, context: context, auto: true, now: now)
                finish(context: context, replay: true)
            } catch {
                logger.error("Checkpoint timeout grade failed: \(error.localizedDescription)")
            }

        case .gradeAndAdvance:
            do {
                try grade(.again, context: context, auto: true, now: now)
                finish(context: context, replay: false)
            } catch {
                logger.error("Checkpoint timeout grade failed: \(error.localizedDescription)")
            }

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

    private func grade(_ grade: ReviewGrade, context: Context, auto: Bool, now: Date) throws {
        try database.write { db in
            guard
                let result = try FlashcardDAO.grade(
                    cardID: context.flashcardID,
                    grade: grade.rawValue,
                    now: now,
                    in: db
                )
            else {
                throw PersistenceError.flashcardMissing(context.flashcardID)
            }

            let metadataJSON = try FlashcardReviewMetadata(
                card: result.original,
                grade: grade.rawValue,
                auto: auto ? true : nil
            ).encodedJSONString()
            try RealTimeEventDAO.log(
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: result.original.audiobookID,
                mediaTimestamp: result.original.mediaTimestamp,
                startedAt: now,
                endedAt: now,
                title: result.original.frontText,
                subtitle: auto ? "Grade: \(grade.rawValue) (auto)" : "Grade: \(grade.rawValue)",
                metadataJSON: metadataJSON,
                sourceItemID: result.original.id,
                sourceItemType: "flashcard",
                in: db
            )
        }
    }

    private func finishOrStartQuiz(context: Context, replay: Bool, now: Date) {
        if !(isScreenOn?() ?? true) {
            announceWaitingCardsIfNeeded(context: context, now: now)
            finish(context: context, replay: replay)
            return
        }

        do {
            try releasePendingQuizCards(
                audiobookID: context.audiobookID,
                chapterIndex: context.chapterIndex,
                now: now
            )
            let dueCards = try StudyPlanDAO(db: database.writer).dueQuizCards(
                audiobookID: context.audiobookID,
                chapterIndex: context.chapterIndex,
                now: now,
                limit: Self.quizCardCap
            )
            guard !dueCards.isEmpty else {
                finish(context: context, replay: replay)
                return
            }

            pendingFinish = PendingFinish(context: context, replay: replay)
            quizCards = dueCards
            quizPosition = 0
            state = .quizActive(
                QuizContext(
                    audiobookID: context.audiobookID,
                    chapterIndex: context.chapterIndex,
                    chapterTitle: context.chapterTitle
                )
            )
        } catch {
            logger.error("Checkpoint quiz setup failed: \(error.localizedDescription)")
            finish(context: context, replay: replay)
        }
    }

    func gradeQuizCard(_ grade: ReviewGrade, now: Date = Date()) {
        guard case .quizActive = state, let card = currentQuizCard else { return }

        do {
            try database.write { db in
                guard
                    let result = try FlashcardDAO.grade(
                        cardID: card.id,
                        grade: grade.rawValue,
                        now: now,
                        in: db
                    )
                else {
                    throw PersistenceError.flashcardMissing(card.id)
                }

                let metadataJSON = try FlashcardReviewMetadata(
                    card: result.original,
                    grade: grade.rawValue
                ).encodedJSONString()
                try RealTimeEventDAO.log(
                    eventType: RealTimeEventType.flashcardReviewed.rawValue,
                    audiobookID: result.original.audiobookID,
                    mediaTimestamp: result.original.mediaTimestamp,
                    startedAt: now,
                    endedAt: now,
                    title: result.original.frontText,
                    subtitle: "Grade: \(grade.rawValue)",
                    metadataJSON: metadataJSON,
                    sourceItemID: result.original.id,
                    sourceItemType: "flashcard",
                    in: db
                )
            }
            NotificationCenter.default.post(name: .studyQueueDidChange, object: nil)
        } catch {
            logger.error("Checkpoint quiz grade failed: \(error.localizedDescription)")
            return
        }

        quizPosition += 1
        if quizPosition >= quizCards.count {
            endQuiz()
        }
    }

    func dismissQuiz() {
        guard case .quizActive = state else { return }
        endQuiz()
    }

    private func endQuiz() {
        quizCards = []
        quizPosition = 0
        guard let pendingFinish else {
            state = .idle
            onCheckpointResolved?()
            deliverPendingRetirePrompt()
            return
        }

        self.pendingFinish = nil
        finish(context: pendingFinish.context, replay: pendingFinish.replay)
        deliverPendingRetirePrompt()
    }

    private func releasePendingQuizCards(
        audiobookID: String,
        chapterIndex: Int,
        now: Date
    ) throws {
        let dao = StudyPlanDAO(db: database.writer)
        let builder = StudyQueueBuilder(db: database.writer)
        var globalRemaining = settingsProvider().globalNewCardLimit.map { max(0, $0) } ?? Int.max
        var didRelease = false

        for plan in try dao.activePlans().filter({ $0.audiobookID == audiobookID }) {
            guard globalRemaining > 0 else { break }
            let budget = try builder.remainingNewCardBudget(
                plan: plan,
                now: now,
                globalNewCardLimit: globalRemaining
            )
            let itemIDs = try dao.pendingCardItemIDs(
                planID: plan.id,
                chapterIndex: chapterIndex,
                limit: budget
            )
            guard !itemIDs.isEmpty else { continue }

            try dao.releaseCards(itemIDs: itemIDs, now: now)
            globalRemaining -= itemIDs.count
            didRelease = true
        }

        guard didRelease,
              let prompt = try StudyChapterRetireService(db: database.writer)
                  .promptForDrainedChapter(
                      audiobookID: audiobookID,
                      chapterIndex: chapterIndex,
                      now: now
                  )
        else {
            return
        }
        pendingRetirePrompt = prompt
    }

    private func announceWaitingCardsIfNeeded(context: Context, now: Date) {
        do {
            let waitingCount = try waitingQuizCardCount(
                audiobookID: context.audiobookID,
                chapterIndex: context.chapterIndex,
                now: now
            )
            if waitingCount > 0 {
                announce(String(localized: "\(waitingCount) cards waiting for review."))
            }
        } catch {
            logger.error("Checkpoint quiz cue lookup failed: \(error.localizedDescription)")
        }
    }

    private func waitingQuizCardCount(
        audiobookID: String,
        chapterIndex: Int,
        now: Date
    ) throws -> Int {
        let dao = StudyPlanDAO(db: database.writer)
        let dueCount = try dao.dueQuizCards(
            audiobookID: audiobookID,
            chapterIndex: chapterIndex,
            now: now,
            limit: Int.max
        ).count
        let pendingCount = try dao.activePlans()
            .filter { $0.audiobookID == audiobookID }
            .reduce(0) { total, plan in
                total + (try dao.pendingCardItemIDs(
                    planID: plan.id,
                    chapterIndex: chapterIndex,
                    limit: Int.max
                ).count)
            }
        return dueCount + pendingCount
    }

    private func deliverPendingRetirePrompt() {
        guard let prompt = pendingRetirePrompt else { return }
        pendingRetirePrompt = nil
        onRetirePrompt?(prompt)
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
                if let itemID = next.planItemID {
                    try StudyPlanDAO(db: database.writer).markIntroduced(itemIDs: [itemID])
                }
                deferredBoundary = nil
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

    private struct PendingFinish {
        let context: Context
        let replay: Bool
    }
}
