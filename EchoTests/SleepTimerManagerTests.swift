import Foundation
import Testing

@testable import Echo

/// Locks in the one-shot-at-cutoff contract that the narration at-gap
/// overshoot fix depends on. PlayerModel.onFire clears
/// `state.awaitingNarrationChapter`; that clear is only correct because onFire
/// runs exactly once, at the real sleep cutoff — never per countdown tick.
///
/// These tests construct SleepTimerManager directly (no PlayerModel), so they
/// avoid the known iOS-26-simulator isolated-deinit teardown crash that makes
/// full-PlayerModel unit tests flaky. The end-of-chapter path is fully
/// synchronous (no Timer/RunLoop wait), so the assertions are deterministic.
@MainActor
@Suite struct SleepTimerManagerTests {

    /// End-of-chapter mode: evaluateAtChapterEnd() must fire onFire exactly once
    /// and leave the manager disarmed (mode == .off). The fix in PlayerModel's
    /// onFire clears the narration auto-resume flag here, so it must run once and
    /// only at the cutoff.
    @Test func endOfChapterFiresOnceAndDisarms() {
        let manager = SleepTimerManager()
        var fireCount = 0
        manager.onFire = { fireCount += 1 }

        manager.setTimer(.endOfChapter)
        manager.evaluateAtChapterEnd()

        #expect(fireCount == 1)
        #expect(manager.mode == .off)
    }

    /// onFire is the cutoff callback, NOT the per-tick callback. A second
    /// evaluateAtChapterEnd() after the timer has already fired (mode now .off)
    /// must not re-fire — guaranteeing the flag-clear in PlayerModel's onFire
    /// happens once per cutoff, not repeatedly.
    @Test func evaluateAfterFireDoesNotRefire() {
        let manager = SleepTimerManager()
        var fireCount = 0
        manager.onFire = { fireCount += 1 }

        manager.setTimer(.endOfChapter)
        manager.evaluateAtChapterEnd()
        // Timer already fired and disarmed; a stray re-evaluation must be inert.
        manager.evaluateAtChapterEnd()

        #expect(fireCount == 1)
        #expect(manager.mode == .off)
    }

    /// evaluateAtChapterEnd() only fires in end-of-chapter mode. In a timed
    /// countdown (or off), a chapter boundary must not trigger onFire — the
    /// countdown owns its own cutoff via the 1s timer.
    @Test func evaluateInMinutesModeDoesNotFire() {
        let manager = SleepTimerManager()
        var fireCount = 0
        manager.onFire = { fireCount += 1 }

        manager.setTimer(.minutes(30))
        manager.evaluateAtChapterEnd()

        #expect(fireCount == 0)
        #expect(manager.mode == .minutes(30))

        // Cleanup: disarm the live 1s timer so it cannot fire during teardown.
        manager.cancel()
    }
}
