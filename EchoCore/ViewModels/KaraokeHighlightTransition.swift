// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure decision for moving the read-along (karaoke) word highlight between
/// paragraph cells, kept out of the view so it's unit-testable.
///
/// The bug it fixes: the imperative retint path only ever *applied* the
/// highlight to the new active word's cell and never cleared the previous one,
/// so when playback crossed a paragraph boundary the prior paragraph's last word
/// stayed lit. This answers "which block's highlight must I clear?" — the
/// previous block, unless the new active word is still inside it.
enum KaraokeHighlightTransition {
    /// The block id whose highlight should be cleared, or `nil` if nothing needs
    /// clearing (no previous highlight, or the active word stayed in the same block).
    static func blockToClear(previous: String?, next: String?) -> String? {
        previous == next ? nil : previous
    }
}
