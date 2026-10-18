// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct WatchDurableContextPolicyTests {
    @Test func significantChangesAlwaysRefreshDurableContext() {
        var policy = WatchDurableContextPolicy(minimumProgressInterval: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let shouldRefresh = policy.shouldRefreshDurableContext(
            reason: .significant,
            context: ["isPlaying": false],
            now: now
        )

        #expect(shouldRefresh)
    }

    @Test func pausedProgressDoesNotRefreshDurableContext() {
        var policy = WatchDurableContextPolicy(minimumProgressInterval: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let shouldRefresh = policy.shouldRefreshDurableContext(
            reason: .progress,
            context: ["isPlaying": false],
            now: now
        )

        #expect(!shouldRefresh)
    }

    @Test func firstPlayingProgressRefreshesDurableContext() {
        var policy = WatchDurableContextPolicy(minimumProgressInterval: 30)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let shouldRefresh = policy.shouldRefreshDurableContext(
            reason: .progress,
            context: ["isPlaying": true],
            now: now
        )

        #expect(shouldRefresh)
    }

    @Test func playingProgressRefreshesDurableContextOnCadence() {
        var policy = WatchDurableContextPolicy(minimumProgressInterval: 30)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        let significantRefresh = policy.shouldRefreshDurableContext(
            reason: .significant,
            context: ["isPlaying": true],
            now: start
        )
        let earlyProgressRefresh = policy.shouldRefreshDurableContext(
            reason: .progress,
            context: ["isPlaying": true],
            now: start.addingTimeInterval(29)
        )
        let onCadenceProgressRefresh = policy.shouldRefreshDurableContext(
            reason: .progress,
            context: ["isPlaying": true],
            now: start.addingTimeInterval(30)
        )

        #expect(significantRefresh)
        #expect(!earlyProgressRefresh)
        #expect(onCadenceProgressRefresh)
    }
}
