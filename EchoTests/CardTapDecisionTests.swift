// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct CardTapDecisionTests {
    @Test func timedBlockSeeksAndPlays() {
        #expect(CardTapDecision.make(time: 12.5) == .seekAndPlay(seconds: 12.5))
    }

    @Test func zeroIsAValidStartTime() {
        #expect(CardTapDecision.make(time: 0) == .seekAndPlay(seconds: 0))
    }

    @Test func missingTimeIsNoTime() {
        #expect(CardTapDecision.make(time: nil) == .noTime)
    }

    @Test func sentinelNegativeIsNoTime() {
        // Un-narrated / un-aligned blocks store audio_start_time = -1.
        #expect(CardTapDecision.make(time: -1) == .noTime)
    }
}
