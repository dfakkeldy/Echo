// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ABSProgressSyncTests {
    @Test func noPushWhenPaused() {
        #expect(
            ABSProgressSync.shouldPush(now: 100, lastPushAt: nil, minInterval: 20, isPlaying: false)
                == false)
    }
    @Test func firstPushWhenPlaying() {
        #expect(
            ABSProgressSync.shouldPush(now: 100, lastPushAt: nil, minInterval: 20, isPlaying: true)
                == true)
    }
    @Test func throttledWithinInterval() {
        #expect(
            ABSProgressSync.shouldPush(now: 110, lastPushAt: 100, minInterval: 20, isPlaying: true)
                == false)
    }
    @Test func pushAfterInterval() {
        #expect(
            ABSProgressSync.shouldPush(now: 125, lastPushAt: 100, minInterval: 20, isPlaying: true)
                == true)
    }
    @Test func finishedNearEnd() {
        #expect(ABSProgressSync.isFinished(currentTime: 3590, duration: 3600) == true)
        #expect(ABSProgressSync.isFinished(currentTime: 1800, duration: 3600) == false)
        #expect(ABSProgressSync.isFinished(currentTime: 10, duration: 0) == false)
    }
}
