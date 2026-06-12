import Testing
@testable import Echo

struct SleepTimerPillStateTests {
    @Test func offModeHasNoLabel() {
        #expect(SleepTimerPillState.labelText(mode: .off, remainingSeconds: 0) == nil)
    }

    @Test func minutesModeShowsCountdown() {
        #expect(SleepTimerPillState.labelText(mode: .minutes(30), remainingSeconds: 1335) == "22:15")
    }

    @Test func minutesModeOverAnHourUsesHoursMinutes() {
        // 3725s = 1h 02m → "1:02" (sleepTimerCountdownText's h:mm fallback)
        #expect(SleepTimerPillState.labelText(mode: .minutes(90), remainingSeconds: 3725) == "1:02")
    }

    @Test func endOfChapterShowsEOC() {
        #expect(SleepTimerPillState.labelText(mode: .endOfChapter, remainingSeconds: 0) == "EOC")
    }
}
