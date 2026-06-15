import Foundation
import os.log

/// FSRS-4.5 (Free Spaced Repetition Scheduler), the 17-parameter version.
///
/// Ported from the canonical algorithm description and the reference Rust
/// implementation (fsrs-rs). The default `w` vector below is the official
/// FSRS-4.5 default parameter set.
///
/// Reference: https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm
///
/// Grades use the four-button scale: 1 = Again, 2 = Hard, 3 = Good, 4 = Easy.
/// A card's memory state is the pair `(stability, difficulty)`; a card with no
/// `stability` yet is treated as a first review and seeded from the initial DSR.
nonisolated struct FSRSScheduler: SchedulingAlgorithm {
    /// Official FSRS-4.5 default parameters (MIT-licensed, from fsrs-rs).
    let w: [Double] = [
        0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01,
        1.49, 0.14, 0.94, 2.18, 0.05, 0.34, 1.26, 0.29, 2.61,
    ]

    /// Forgetting-curve constants. `R(S, S) = 0.9` by construction.
    let decay: Double = -0.5
    let factor: Double = 19.0 / 81.0

    /// Desired retention used to convert a stability into a day-interval.
    let requestedRetention: Double = 0.9

    let minimumStability: Double = 0.01
    let maximumStability: Double = 36_500.0

    /// Largest day-interval we will ever schedule (≈100 years). Clamping here
    /// keeps `Calendar.date(byAdding:)` from overflowing on huge stabilities
    /// (audit §5.4).
    private let maximumIntervalDays = 36_500

    private static let logger = Logger(category: "FSRSScheduler")

    func review(card: Flashcard, grade: Int, now: Date) -> Flashcard {
        var updated = card
        let g = max(1, min(4, grade))

        let newStability: Double
        let newDifficulty: Double

        if let priorStability = card.stability, let priorDifficulty = card.difficulty {
            // Subsequent review: evolve the memory state from the prior (S, D).
            // The stability formulas use the *prior* difficulty (matching fsrs-rs);
            // difficulty is updated independently.
            let elapsedDays = elapsedDaysSinceLastReview(card.lastReviewedAt, now: now)
            let r = retrievability(elapsedDays: elapsedDays, stability: priorStability)
            newDifficulty = nextDifficulty(priorDifficulty, grade: g)
            newStability =
                g >= 2
                ? stabilityAfterRecall(
                    stability: priorStability, difficulty: priorDifficulty, retrievability: r,
                    grade: g)
                : stabilityAfterLapse(
                    stability: priorStability, difficulty: priorDifficulty, retrievability: r)
        } else {
            // First review: seed the memory state from the initial DSR. No
            // forgetting curve is applied because there is no prior interval.
            newStability = initialStability(g)
            newDifficulty = initialDifficulty(g)
        }

        let stability = clamp(newStability, lo: minimumStability, hi: maximumStability)
        let interval = nextInterval(stability: stability)

        updated.stability = stability
        updated.difficulty = newDifficulty
        updated.intervalDays = interval
        updated.repetitions = card.repetitions + 1
        updated.lastReviewedAt = now.ISO8601Format()
        updated.lastGrade = grade
        updated.modifiedAt = now.ISO8601Format()

        if let nextDate = Calendar.current.date(byAdding: .day, value: interval, to: now) {
            updated.nextReviewDate = nextDate.ISO8601Format()
        } else {
            // Should be unreachable now that `interval` is clamped, but never
            // silently drop the schedule (audit §5.4).
            Self.logger.error(
                "Calendar overflow scheduling interval \(interval) days from \(now); leaving nextReviewDate unchanged"
            )
        }

        return updated
    }

    // MARK: - Initial DSR (first review)

    /// `S₀(G) = w[G-1]` — the first four weights are the per-grade initial stabilities.
    private func initialStability(_ grade: Int) -> Double {
        clamp(w[grade - 1], lo: minimumStability, hi: maximumStability)
    }

    /// `D₀(G) = w₄ - w₅·(G-3)`, clamped to [1, 10].
    private func initialDifficulty(_ grade: Int) -> Double {
        clampDifficulty(w[4] - w[5] * Double(grade - 3))
    }

    // MARK: - Updates (subsequent review)

    /// `D'(D,G) = w₇·D₀(3) + (1 - w₇)·(D - w₆·(G-3))`, clamped to [1, 10].
    /// Mean-reverts toward the Good-grade initial difficulty.
    private func nextDifficulty(_ difficulty: Double, grade: Int) -> Double {
        let linear = difficulty - w[6] * Double(grade - 3)
        let reverted = w[7] * initialDifficulty(3) + (1.0 - w[7]) * linear
        return clampDifficulty(reverted)
    }

    /// Recall (G ≥ 2):
    /// `S·(1 + e^{w₈}·(11-D)·S^{-w₉}·(e^{w₁₀·(1-R)} - 1)·hardPenalty·easyBonus)`.
    /// `hardPenalty = w₁₅` only when G == 2 (Hard); `easyBonus = w₁₆` only when G == 4 (Easy).
    private func stabilityAfterRecall(
        stability: Double, difficulty: Double, retrievability r: Double, grade: Int
    ) -> Double {
        let hardPenalty = grade == 2 ? w[15] : 1.0
        let easyBonus = grade == 4 ? w[16] : 1.0
        return stability
            * (1.0
                + exp(w[8])
                * (11.0 - difficulty)
                * pow(stability, -w[9])
                * (exp(w[10] * (1.0 - r)) - 1.0)
                * hardPenalty
                * easyBonus)
    }

    /// Lapse (G = 1): `w₁₁·D^{-w₁₂}·((S+1)^{w₁₃} - 1)·e^{w₁₄·(1-R)}`.
    private func stabilityAfterLapse(
        stability: Double, difficulty: Double, retrievability r: Double
    ) -> Double {
        w[11]
            * pow(difficulty, -w[12])
            * (pow(stability + 1.0, w[13]) - 1.0)
            * exp(w[14] * (1.0 - r))
    }

    // MARK: - Forgetting curve & interval

    /// `R(t,S) = (1 + FACTOR·t/S)^DECAY`.
    private func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1.0 + factor * elapsedDays / max(stability, minimumStability), decay)
    }

    /// `I(r,S) = (S/FACTOR)·(r^{1/DECAY} - 1)`, rounded and clamped to
    /// [1, maximumIntervalDays]. With r = 0.9 this is ≈ S days.
    private func nextInterval(stability: Double) -> Int {
        let raw = (stability / factor) * (pow(requestedRetention, 1.0 / decay) - 1.0)
        return min(max(1, Int(raw.rounded())), maximumIntervalDays)
    }

    // MARK: - Helpers

    private func elapsedDaysSinceLastReview(_ lastReviewedAt: String?, now: Date) -> Double {
        let last = lastReviewedAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
        return max(0, now.timeIntervalSince(last) / 86_400.0)
    }

    private func clampDifficulty(_ value: Double) -> Double { clamp(value, lo: 1.0, hi: 10.0) }

    private func clamp(_ value: Double, lo: Double, hi: Double) -> Double {
        min(max(value, lo), hi)
    }
}
