// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

struct SmartRewindPolicyTests {
    private let policy = SmartRewindPolicy(
        secondsThreshold: 30, secondsAmount: 10,
        minutesThreshold: 10, minutesAmount: 30,
        hoursThreshold: 2, hoursAmount: 120
    )

    @Test func shortPauseRewindsShortAmount() {
        #expect(policy.rewindAmount(forPausedDuration: 45) == 10)
    }

    @Test func mediumPauseOverridesShortRule() {
        #expect(policy.rewindAmount(forPausedDuration: 12 * 60) == 30)
    }

    @Test func longPauseOverridesAll() {
        #expect(policy.rewindAmount(forPausedDuration: 3 * 3600) == 120)
    }

    @Test func belowThresholdRewindsNothing() {
        #expect(policy.rewindAmount(forPausedDuration: 5) == 0)
    }

    @Test func exampleTextDescribesTheMediumRule() {
        #expect(policy.exampleText(forPausedMinutes: 12) == "Paused 12 min → rewinds 30 s")
    }
}
