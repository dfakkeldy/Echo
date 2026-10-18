// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct SleepTimerPillStateTests {
    @Test func offModeHasNoLabel() {
        #expect(SleepTimerPillState.labelText(mode: .off, remainingSeconds: 0) == nil)
    }

    @Test func minutesModeShowsCountdown() {
        #expect(
            SleepTimerPillState.labelText(mode: .minutes(30), remainingSeconds: 1335) == "22:15")
    }

    @Test func minutesModeShowsSixtyMinutesAtOneHourBoundary() {
        #expect(SleepTimerPillState.labelText(mode: .minutes(60), remainingSeconds: 3600) == "60:00")
    }

    @Test func minutesModeOverAnHourUsesHoursMinutes() {
        // 3725s = 1h 02m → "1:02" (sleepTimerCountdownText's h:mm fallback)
        #expect(SleepTimerPillState.labelText(mode: .minutes(90), remainingSeconds: 3725) == "1:02")
    }

    @Test func endOfChapterShowsEOC() {
        #expect(SleepTimerPillState.labelText(mode: .endOfChapter, remainingSeconds: 0) == "EOC")
    }

    @Test func minutesModeExactlyOneHourShowsMinutesNotAmbiguousHour() {
        // 3600s = the "1 Hour" preset's first tick. Must read "60:00", not the
        // "1:00" that is indistinguishable from a one-minute countdown.
        #expect(
            SleepTimerPillState.labelText(mode: .minutes(60), remainingSeconds: 3600) == "60:00")
    }
    @Test func timerAccessibilityValuesDescribeAllModes() {
        #expect(
            SleepTimerPillState.accessibilityValue(mode: .off, remainingSeconds: 0) == "Off"
        )
        #expect(
            SleepTimerPillState.accessibilityValue(
                mode: .minutes(30), remainingSeconds: 1335
            ) == "30 minutes, 1335 seconds remaining"
        )
        #expect(
            SleepTimerPillState.accessibilityValue(
                mode: .endOfChapter, remainingSeconds: 0
            ) == "End of Chapter"
        )
    }

    @Test func activeMenuStatusIsAbsentWhenOffAndConciseWhenArmed() {
        #expect(SleepTimerPillState.activeStatusText(mode: .off, remainingSeconds: 0) == nil)
        #expect(
            SleepTimerPillState.activeStatusText(
                mode: .minutes(30), remainingSeconds: 1335
            ) == "Remaining: 22:15"
        )
        #expect(
            SleepTimerPillState.activeStatusText(
                mode: .endOfChapter, remainingSeconds: 0
            ) == "End of Chapter"
        )
    }
}
