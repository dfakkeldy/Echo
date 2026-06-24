// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

/// The "No audiobook for this one — Echo can narrate it on-device / Listen" nudge
/// must appear ONLY for a book with no audio loaded yet that isn't currently
/// rendering. The bug: it re-appeared on a fully-narrated book because the render
/// having *completed* flips `isRunning` back to false.
@Suite struct NarrationNudgePolicyTests {

    // Fresh, un-narrated EPUB: no tracks loaded, nothing rendering → offer narration.
    @Test func showsNudgeForFreshEPUB() {
        #expect(NarrationNudgePolicy.showsNudge(tracksEmpty: true, isRunning: false) == true)
    }

    // Fully narrated book: render completed (isRunning == false) but tracks are
    // loaded and playing → the nudge must STAY hidden. This is the reported bug.
    @Test func hidesNudgeForFullyNarratedBook() {
        #expect(NarrationNudgePolicy.showsNudge(tracksEmpty: false, isRunning: false) == false)
    }

    // Mid-render: chapter 1 is queued (tracks non-empty) while rendering ahead → hidden.
    @Test func hidesNudgeWhileRendering() {
        #expect(NarrationNudgePolicy.showsNudge(tracksEmpty: false, isRunning: true) == false)
    }

    // Engine preparing before the first track is queued → hidden (don't flash the
    // offer while a render is spinning up).
    @Test func hidesNudgeWhilePreparingBeforeFirstTrack() {
        #expect(NarrationNudgePolicy.showsNudge(tracksEmpty: true, isRunning: true) == false)
    }
}
