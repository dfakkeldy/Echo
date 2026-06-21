// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure formatting of narration prepare progress into a lock-screen subtitle, so
/// a multi-minute chapter-0 render reads as motion rather than a frozen "Preparing
/// narration…". At fraction 0 the percent is omitted (we haven't synthesized a
/// block yet); above 0 it appends a clamped whole-percent.
enum NarrationProgressText {
    static func subtitle(chapterDisplayNumber: Int, fraction: Double) -> String {
        let base = "Preparing chapter \(chapterDisplayNumber)…"
        guard fraction > 0 else { return base }
        let pct = Int((min(max(fraction, 0), 1) * 100).rounded())
        return "\(base) \(pct)%"
    }
}
