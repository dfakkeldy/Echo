import Foundation
import os.log

// MARK: - InlineFlashcardTriggerController

/// Manages inline flashcard trigger detection, deduplication, and grading.
/// PlayerModel owns the active card (`activeInlineCard`) and handles audio
/// pause/resume; this controller handles the pure logic of when to fire
/// and how to grade.
final class InlineFlashcardTriggerController {

    // MARK: - Trigger state

    /// Cached flashcards for the current track, loaded once on track change.
    var cachedTrackFlashcards: [Flashcard] = []
    /// Key used to invalidate the flashcard cache on track switch.
    var cachedTrackFlashcardKey: String = ""
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
        if cachedTrackFlashcardKey != trackKey, let db = databaseServiceProvider?() {
            do {
                cachedTrackFlashcards = try FlashcardDAO(db: db.writer).flashcards(for: trackKey)
            } catch {
                os_log(.error, "Failed to load flashcards for track %{public}@: %{public}@", trackKey, error.localizedDescription)
                cachedTrackFlashcards = []
            }
            cachedTrackFlashcardKey = trackKey
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

    /// Grades the given flashcard in the database.
    func gradeCard(_ grade: Int, cardID: String) {
        guard let db = databaseServiceProvider?() else { return }
        do {
            try FlashcardDAO(db: db.writer).grade(cardID: cardID, grade: grade)
        } catch {
            os_log(.error, "Failed to grade flashcard %{public}@: %{public}@", cardID, error.localizedDescription)
        }
    }

    /// Resets trigger state for a new track.
    func resetForNewTrack() {
        triggeredFlashcardIDs.removeAll()
        lastFlashcardTriggerSecond = -1
    }
}
