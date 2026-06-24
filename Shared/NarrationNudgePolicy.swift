// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides whether the Now Playing screen shows the "No audiobook for this one —
/// Echo can narrate it on-device / Listen" nudge (and the voice picker beneath it).
///
/// The nudge is an **offer to narrate a book that has no audio yet**, so it must
/// appear only when the book genuinely has nothing to play and isn't already
/// rendering. The bug it fixes: `NarrationState.isRunning` returns `false` once a
/// render *completes* (`.completed`), so gating on `!isRunning` alone re-showed
/// "No audiobook" on a fully-narrated book sitting at hours on the scrubber.
/// Requiring `tracksEmpty` keeps the offer for a fresh, un-narrated EPUB (no tracks
/// loaded) while hiding it the instant any audio is queued — mid-render OR completed.
/// `tracks.isEmpty` is the app's established "audio loaded" signal (UnifiedBottomDock,
/// TransportControlsView), and an imported audiobook that also carries EPUB text gets
/// its tracks at load, so it is correctly never nagged.
enum NarrationNudgePolicy {

    /// - Parameters:
    ///   - tracksEmpty: `model.tracks.isEmpty` — true only when no playable audio is loaded.
    ///   - isRunning: `model.narrationPlaybackState.isRunning` — true while a render is in flight.
    /// - Returns: whether to show the narrate-this-book nudge + voice picker.
    static func showsNudge(tracksEmpty: Bool, isRunning: Bool) -> Bool {
        tracksEmpty && !isRunning
    }
}
