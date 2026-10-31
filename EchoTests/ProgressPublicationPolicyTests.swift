// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ProgressPublicationPolicyTests {
    private static let tick: TimeInterval = 0.5
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Plays `ticks` timer ticks through a chapter of `chapterSeconds`, applying
    /// any `seeks` (tick index → seconds jumped) before that tick, and returns
    /// the wall-clock times of the ticks that published.
    private func publishTimes(
        chapterSeconds: TimeInterval,
        ticks: Int = 120,
        seeks: [Int: TimeInterval] = [:],
        policy: inout ProgressPublicationPolicy
    ) -> [TimeInterval] {
        var position: TimeInterval = 60
        var published: [TimeInterval] = []
        for i in 0..<ticks {
            position += Self.tick + (seeks[i] ?? 0)
            let wall = TimeInterval(i) * Self.tick
            if policy.shouldPublish(
                fraction: position / chapterSeconds, isPlaying: true,
                now: Self.start.addingTimeInterval(wall))
            {
                published.append(wall)
            }
        }
        return published
    }

    private func maxGap(_ times: [TimeInterval], through end: TimeInterval) -> TimeInterval {
        zip(times + [end], [0] + times).map { $0 - $1 }.max() ?? .infinity
    }

    @Test(arguments: [20 * 60.0, 3 * 3600.0])
    func longChapterPublishesWithinFiveSeconds(chapterSeconds: TimeInterval) {
        var policy = ProgressPublicationPolicy()
        let times = publishTimes(chapterSeconds: chapterSeconds, policy: &policy)
        #expect(times.first == 0)
        #expect(times.count > 1)
        #expect(maxGap(times, through: 119 * Self.tick) <= 5.0)
    }

    @Test func smallSeeksOnLongChapterStillPublishWithinFiveSeconds() {
        // A 30 s jump is 0.28% of three hours, under the fraction threshold.
        var policy = ProgressPublicationPolicy()
        let times = publishTimes(
            chapterSeconds: 3 * 3600, seeks: [40: 30, 41: -15, 80: 10], policy: &policy)
        #expect(maxGap(times, through: 119 * Self.tick) <= 5.0)
    }

    @Test func largeSeekPublishesOnTheSameTick() {
        var policy = ProgressPublicationPolicy()
        // Two minutes on a 20-minute chapter is a 10% jump.
        let times = publishTimes(chapterSeconds: 20 * 60, seeks: [33: 120], policy: &policy)
        #expect(times.contains(33 * Self.tick))
    }

    @Test func shortChapterPublishesWheneverPerTickComparisonDid() {
        // A 60 s chapter moves 0.83% per tick, so the old per-tick rule fired
        // every tick. The fix must not publish less often than that.
        let chapterSeconds: TimeInterval = 60
        var policy = ProgressPublicationPolicy()
        var position: TimeInterval = 0
        var previousFraction: Double = 0
        var oldRuleFired = 0
        for i in 0..<100 {
            position += Self.tick
            let fraction = position / chapterSeconds
            let oldRuleFires = abs(previousFraction - fraction) > 0.005
            previousFraction = fraction
            let fires = policy.shouldPublish(
                fraction: fraction, isPlaying: true,
                now: Self.start.addingTimeInterval(TimeInterval(i) * Self.tick))
            if oldRuleFires {
                oldRuleFired += 1
                #expect(fires, "tick \(i)")
            }
        }
        #expect(oldRuleFired == 100)
    }

    @Test func pausedPositionDoesNotRepublishAsTimePasses() {
        var policy = ProgressPublicationPolicy()
        #expect(policy.shouldPublish(fraction: 0.4, isPlaying: false, now: Self.start))
        for second in 1...60 {
            let fires = policy.shouldPublish(
                fraction: 0.4, isPlaying: false,
                now: Self.start.addingTimeInterval(TimeInterval(second)))
            #expect(!fires, "second \(second)")
        }
    }

    @Test func pausedSeekPublishes() {
        var policy = ProgressPublicationPolicy()
        _ = policy.shouldPublish(fraction: 0.4, isPlaying: false, now: Self.start)
        let fires = policy.shouldPublish(
            fraction: 0.5, isPlaying: false, now: Self.start.addingTimeInterval(1))
        #expect(fires)
    }

    @Test func resetPublishesTheNextTickAtOnce() {
        var policy = ProgressPublicationPolicy()
        _ = policy.shouldPublish(fraction: 0.4, isPlaying: true, now: Self.start)
        let beforeReset = policy.shouldPublish(
            fraction: 0.4, isPlaying: true, now: Self.start.addingTimeInterval(1))
        #expect(!beforeReset)
        policy.reset()
        let afterReset = policy.shouldPublish(
            fraction: 0.4, isPlaying: true, now: Self.start.addingTimeInterval(1.5))
        #expect(afterReset)
    }
}
