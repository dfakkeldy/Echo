import Foundation

/// SM-2 spaced repetition algorithm.
///
/// Implements the classic SM-2 algorithm from SuperMemo:
/// - Grades >= 3 are correct responses that increase the interval.
/// - Grades < 3 reset repetitions and interval to 1 day.
/// - Ease factor has a floor of 1.3.
nonisolated struct SM2Scheduler: SchedulingAlgorithm {
    func review(card: Flashcard, grade: Int, now: Date) -> Flashcard {
        var updated = card

        if grade >= 3 {
            if updated.repetitions == 0 {
                updated.intervalDays = 1
            } else if updated.repetitions == 1 {
                updated.intervalDays = 6
            } else {
                let newInterval = Double(updated.intervalDays) * updated.easeFactor
                updated.intervalDays = Int(newInterval)
            }
            updated.repetitions += 1
        } else {
            updated.repetitions = 0
            updated.intervalDays = 1
        }

        updated.easeFactor = max(
            1.3,
            updated.easeFactor + (0.1 - Double(5 - grade) * (0.08 + Double(5 - grade) * 0.02))
        )
        updated.lastReviewedAt = now.ISO8601Format()
        updated.lastGrade = grade
        updated.modifiedAt = now.ISO8601Format()

        if let nextDate = Calendar.current.date(
            byAdding: .day, value: updated.intervalDays, to: now
        ) {
            updated.nextReviewDate = nextDate.ISO8601Format()
        }

        return updated
    }
}
