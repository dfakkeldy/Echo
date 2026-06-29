// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Shared time formatting utility. Formats a TimeInterval as [H:]MM:SS.
/// Returns "--:--" for non-finite or NaN values.
///
/// `nonisolated`: a pure value→String helper (no main-actor state). Under the
/// Swift 6 `-default-isolation MainActor` mode it would otherwise be inferred
/// `@MainActor`, which `nonisolated` callers (e.g. `Bookmark.markdownExport` on
/// the nonisolated `Bookmark`) cannot invoke synchronously.
public nonisolated func formatHMS(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, !seconds.isNaN else { return "--:--" }
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    let paddedMinute = m.formatted(.number.precision(.integerLength(2)))
    let paddedSecond = s.formatted(.number.precision(.integerLength(2)))
    if h > 0 {
        return "\(h):\(paddedMinute):\(paddedSecond)"
    }
    return "\(paddedMinute):\(paddedSecond)"
}
