import Foundation
import os.log

// MARK: - InlineFlashcardTriggerController

/// Manages inline flashcard trigger detection, deduplication, and grading.
/// PlayerModel owns the active card (`activeInlineCard`) and handles audio
/// pause/resume; this controller handles the pure logic of when to fire
/// and how to grade.
@MainActor
final class InlineFlashcardTriggerController {

    // MARK: - Trigger state

    /// Cached flashcards for the current track, loaded once on track change.
    var cachedTrackFlashcards: [Flashcard] = []
    /// Key used to invalidate the flashcard cache on track switch.
    var cachedTrackFlashcardKey: String = ""
    /// Whether a flashcard cache load is in flight for the current track.
    var isLoadingFlashcards = false
    /// Set of already-triggered flashcard IDs to prevent re-firing on seek/loop.
    var triggeredFlashcardIDs: Set<String> = []
    /// Player time at which the last flashcard trigger fired, for deduplication.
    var lastFlashcardTriggerSecond: Double = -1
    /// Whether playback was active before a flashcard overlay appeared.
    var wasPlayingBeforeFlashcard: Bool = false

    // MARK: - Dependencies (set by PlayerModel)

    var databaseServiceProvider: (() -> DatabaseService?)?
    var trackKeyProvider: (() -> String)?
    var isPlayingProvider: (() -> Bool)?
    var isManualSeekingProvider: (() -> Bool)?
    var loopModeProvider: (() -> LoopMode)?

    // MARK: - Async cache warm

    /// Loads flashcard cache asynchronously via GRDB async read to avoid
    /// blocking the main thread during playback ticks.
    func loadFlashcards(for trackKey: String) {
        guard !isLoadingFlashcards else { return }
        isLoadingFlashcards = true
        guard let dbService = databaseServiceProvider?() else {
            isLoadingFlashcards = false
            return
        }
        let dao = FlashcardDAO(db: dbService.writer)
        Task.detached { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.isLoadingFlashcards = false
                }
            }
            do {
                // DAO handles its own read transaction internally
                let cards = try dao.flashcards(for: trackKey)
                await MainActor.run { [weak self] in
                    self?.cachedTrackFlashcards = cards
                    self?.cachedTrackFlashcardKey = trackKey
                }
            } catch {
                Logger(category: "FlashcardTrigger").error(
                    "Failed to load flashcards for \(trackKey): \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.cachedTrackFlashcards = []
                    self?.cachedTrackFlashcardKey = trackKey
                }
            }
        }
    }

    // MARK: - Trigger detection

    /// Polls flashcard timestamps on each time tick. Returns a card to display
    /// when playback crosses a trigger point, or `nil` when nothing should fire.
    /// Follows the same tolerance/deduplication pattern as voice memo triggers.
    func checkTrigger(
        at currentSeconds: Double,
        previousSeconds: Double?,
        hasActiveCard: Bool
    ) -> Flashcard? {
        guard !hasActiveCard,
            isPlayingProvider?() == true,
            isManualSeekingProvider?() == false,
            loopModeProvider?() != .bookmark
        else { return nil }

        let toleranceAfter: Double = 0.75

        let trackKey = trackKeyProvider?() ?? ""
        if cachedTrackFlashcardKey != trackKey {
            // Trigger async cache warm; skip flashcard check until loaded.
            loadFlashcards(for: trackKey)
            return nil
        }
        let cards = cachedTrackFlashcards

        for card in cards {
            guard card.triggerTiming != .manualOnly else { continue }
            guard !triggeredFlashcardIDs.contains(card.id) else { continue }

            let triggerTime = card.mediaTimestamp

            let crossed: Bool
            if let prev = previousSeconds, prev.isFinite {
                crossed = prev <= triggerTime && currentSeconds > triggerTime
            } else {
                crossed = abs(currentSeconds - triggerTime) <= toleranceAfter
            }
            guard crossed else { continue }

            if abs(currentSeconds - lastFlashcardTriggerSecond) < 5 { continue }

            lastFlashcardTriggerSecond = currentSeconds
            triggeredFlashcardIDs.insert(card.id)
            wasPlayingBeforeFlashcard = true
            return card
        }

        return nil
    }

    // MARK: - Grading & dismissal

    /// Grades the given flashcard in the database via async write to avoid
    /// blocking the main thread.
    func gradeCard(_ grade: Int, cardID: String) {
        guard let dbService = databaseServiceProvider?() else { return }
        let dao = FlashcardDAO(db: dbService.writer)
        Task.detached {
            do {
                // DAO handles its own write transaction internally
                try dao.grade(cardID: cardID, grade: grade)
            } catch {
                Logger(category: "FlashcardTrigger").error(
                    "Failed to grade flashcard \(cardID): \(error.localizedDescription)")
            }
        }
    }

    /// Resets trigger state for a new track.
    func resetForNewTrack() {
        triggeredFlashcardIDs.removeAll()
        lastFlashcardTriggerSecond = -1
    }
}
