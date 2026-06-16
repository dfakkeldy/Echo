// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Shared text-alignment utilities
//
// These pure functions are used by both EchoCore (AutoAlignmentService,
// ChapterTitleMatcher) and the macOS target (MacGlobalAlignmentService).
// Keeping them in Shared/ prevents the kind of silent duplication that
// caused the macOS target to rot unnoticed (§5.1 / §9.3).

// MARK: - Tokenization

private let nonLetters = CharacterSet.letters.inverted

/// Splits text into lowercase word tokens of 2+ letters for fuzzy matching.
/// - Parameter text: The source text (may contain punctuation, whitespace, mixed case).
/// - Returns: Lowercased word tokens with length ≥ 2.
public func tokenizeForAlignment(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: nonLetters)
        .filter { $0.count >= 2 }
}

// MARK: - Jaccard word-overlap scoring

/// Computes the Jaccard similarity coefficient between a block token set and a
/// transcript candidate slice.  Both inputs are already lowercased word tokens.
///
/// - Parameters:
///   - blockSet: Pre-computed `Set<String>` of the reference (block) tokens.
///   - candidateSlice: A slice of transcript tokens to compare against.
/// - Returns: Jaccard score in [0, 1], or 0 when the union is empty.
public func jaccardScore(blockSet: Set<String>, candidateSlice: ArraySlice<String>) -> Double {
    let transSet = Set(candidateSlice)
    let intersection = blockSet.intersection(transSet).count
    let union = blockSet.union(transSet).count
    guard union > 0 else { return 0 }
    return Double(intersection) / Double(union)
}

// MARK: - Time formatting

/// Formats a time interval as a human-readable string.
/// - Returns: `HH:MM:SS` when ≥ 1 hour, `MM:SS` otherwise.
public func formatTimeHMS(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
