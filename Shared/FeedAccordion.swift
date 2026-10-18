// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure accordion-state decisions for the unified feed: at most one audio
/// chapter is expanded at a time. Keyed by audio chapter index (`Int`), with
/// `nil` meaning "all collapsed". No UIKit / no DB so iOS and a future macOS
/// feed can share it.
enum FeedAccordion {
    /// Result of tapping a chapter header: open `tapped`, or collapse it when it
    /// is already the open chapter (so a second tap closes).
    static func toggled(current: Int?, tapped: Int) -> Int? {
        current == tapped ? nil : tapped
    }

    /// Playback-driven expansion. When the chapter being played changes to a new
    /// non-nil chapter, force that chapter open (auto-collapsing whatever was
    /// open). When the playing chapter has not changed since the last tick, the
    /// user's manual choice (`current`) is preserved so a deliberate collapse
    /// while staying in the same chapter sticks.
    static func autoExpand(
        current openKey: Int?, playingChapterKey: Int?, lastPlayingChapterKey: Int?
    )
        -> Int?
    {
        guard let playingChapterKey, playingChapterKey != lastPlayingChapterKey else {
            return openKey
        }
        return playingChapterKey
    }
}
