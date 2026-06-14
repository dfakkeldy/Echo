import Foundation

/// Protocol for spaced repetition scheduling algorithms.
///
/// Conformers must be `Sendable` so they can be used across concurrency
/// domains (e.g. inside a `DatabaseWriter.write` block).
protocol SchedulingAlgorithm: Sendable {
    /// Review a flashcard and return an updated copy with new scheduling metadata.
    ///
    /// - Parameters:
    ///   - card: The flashcard before review.
    ///   - grade: User-assigned grade (typically 1–4 or 0–5 depending on the algorithm).
    ///   - now: The current date used for interval calculations.
    /// - Returns: A new `Flashcard` with updated scheduling fields.
    nonisolated func review(card: Flashcard, grade: Int, now: Date) -> Flashcard
}
