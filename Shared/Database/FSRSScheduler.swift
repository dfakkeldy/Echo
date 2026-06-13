import Foundation

/// FSRS (Free Spaced Repetition Scheduler) algorithm ported from fsrs-rs.
///
/// Uses a 17-parameter w vector, forgetting-curve based stability tracking,
/// and separate initialisation paths for first-time vs. reviewed cards.
///
/// Reference: https://github.com/open-spaced-repetition/free-spaced-repetition-scheduler
struct FSRSScheduler: SchedulingAlgorithm {
    /// Default parameter vector (MIT-licensed reference parameters from fsrs-rs).
    let w: [Double] = [
        0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01,
        1.49, 0.14, 0.94, 2.18, 0.05, 0.34, 1.26, 0.29, 2.61
    ]
    let decay: Double = -0.5
    let minimumStability: Double = 0.01
    let maximumStability: Double = 36500.0

    func review(card: Flashcard, grade: Int, now: Date) -> Flashcard {
        var updated = card
        let clampedGrade = max(1, min(4, grade))

        let stability = card.stability ?? initStability(clampedGrade)
        let difficulty = card.difficulty ?? initDifficulty(clampedGrade)

        let newDifficulty = clamp(
            difficulty + w[4] - w[5] * Double(clampedGrade - 3),
            lo: 1.0, hi: 10.0
        )

        let lastReviewed = card.lastReviewedAt
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
        let elapsed = max(0, now.timeIntervalSince(lastReviewed) / 86400.0)
        let retrievability = exp(log(0.9) * elapsed / max(stability, 0.001))

        var newStability: Double
        if clampedGrade >= 3 {
            let hardPenalty = clampedGrade == 3 ? w[15] : 1.0
            let easyBonus = clampedGrade == 4 ? exp(w[16] * (newDifficulty - 1.0)) : 1.0
            newStability = stability * (
                1.0 + exp(w[8]) *
                (11.0 - newDifficulty) *
                pow(stability, -w[9]) *
                (exp(w[10] * (1.0 - retrievability)) - 1.0) *
                hardPenalty * easyBonus
            )
        } else {
            newStability = w[11]
                * pow(newDifficulty, -w[12])
                * (pow(stability + 1.0, w[13]) - 1.0)
                * exp(w[14] * (1.0 - retrievability))
        }
        newStability = clamp(newStability, lo: minimumStability, hi: maximumStability)

        let interval: Int
        if clampedGrade >= 3 {
            interval = max(1, Int(round(newStability * (
                clampedGrade == 4
                    ? w[6] * (2.0 - pow(retrievability, 2.0))
                    : w[7]
            ))))
        } else {
            interval = max(1, Int(round(
                newStability * (1.0 - pow(retrievability, 2.0)) * (1.0 / exp(1.0))
            )))
        }

        updated.stability = newStability
        updated.difficulty = newDifficulty
        updated.intervalDays = interval
        updated.repetitions = card.repetitions + 1
        updated.lastReviewedAt = now.ISO8601Format()
        updated.lastGrade = grade
        updated.modifiedAt = now.ISO8601Format()

        if let nextDate = Calendar.current.date(byAdding: .day, value: interval, to: now) {
            updated.nextReviewDate = nextDate.ISO8601Format()
        }

        return updated
    }

    /// Initial stability for a first-time review.
    private func initStability(_ grade: Int) -> Double {
        grade >= 3 ? w[0] + w[1] * Double(grade - 3) : w[2]
    }

    /// Initial difficulty for a first-time review.
    private func initDifficulty(_ grade: Int) -> Double {
        clamp(w[3] - w[4] * Double(grade - 3), lo: 1.0, hi: 10.0)
    }

    /// Clamp a value to the inclusive range [lo, hi].
    private func clamp(_ value: Double, lo: Double, hi: Double) -> Double {
        min(max(value, lo), hi)
    }
}
