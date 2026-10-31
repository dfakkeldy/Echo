// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// `shouldPublish` is `mutating`, so every call is hoisted into a `let`:
/// `#expect` rewrites a call written inside it into a closure over an
/// immutable copy, which does not compile.
struct ProgressPublicationPolicyTests {
    private static let tick: TimeInterval = 0.5
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Drives the policy the way `PlaybackProgressPresenter.updateProgress()`
    /// does: `displayed` is the fraction the previous tick showed.
    private struct Player {
        var policy = ProgressPublicationPolicy()
        var displayed: Double = 0
        var published: [TimeInterval] = []

        mutating func tick(fraction: Double, isPlaying: Bool = true, at wall: TimeInterval) -> Bool
        {
            let fires = policy.shouldPublish(
                fraction: fraction, displayedFraction: displayed, isPlaying: isPlaying,
                now: ProgressPublicationPolicyTests.start.addingTimeInterval(wall))
            displayed = fraction
            if fires { published.append(wall) }
            return fires
        }
    }

    /// Plays 120 timer ticks through a chapter of `chapterSeconds`, applying
    /// any `seeks` (tick index → seconds jumped) before that tick.
    private func play(
        chapterSeconds: TimeInterval, seeks: [Int: TimeInterval] = [:]
    ) -> Player {
        var player = Player()
        var position: TimeInterval = 60
        for i in 0..<120 {
            position += Self.tick + (seeks[i] ?? 0)
            _ = player.tick(fraction: position / chapterSeconds, at: TimeInterval(i) * Self.tick)
        }
        return player
    }

    private func maxGap(_ times: [TimeInterval], through end: TimeInterval) -> TimeInterval {
        zip(times + [end], [0] + times).map { $0 - $1 }.max() ?? .infinity
    }

    @Test(arguments: [20 * 60.0, 3 * 3600.0])
    func longChapterPublishesEveryFourAndAHalfSecondsAtMost(chapterSeconds: TimeInterval) {
        let times = play(chapterSeconds: chapterSeconds).published
        #expect(times.first == 0)
        #expect(times.count > 1)
        #expect(maxGap(times, through: 119 * Self.tick) <= 4.5)
    }

    @Test func lateTimerTicksStillPublishWithinFiveSeconds() {
        // A repeating Timer stays on its 0.5 s grid; each tick lands up to
        // 0.45 s late on it, in a fixed varied pattern.
        let lateness: [TimeInterval] = [0.45, 0, 0.1, 0.3, 0.05, 0.45, 0.2, 0]
        var player = Player()
        for i in 0..<400 {
            let wall = TimeInterval(i) * Self.tick + lateness[i % lateness.count]
            _ = player.tick(fraction: wall / (3 * 3600), at: wall)
        }
        #expect(maxGap(player.published, through: 399 * Self.tick) < 5.0)
    }

    @Test func smallSeeksOnLongChapterStillPublishOnSchedule() {
        // A 30 s jump is 0.28% of three hours, under the fraction threshold.
        let times = play(chapterSeconds: 3 * 3600, seeks: [40: 30, 41: -15, 80: 10]).published
        #expect(maxGap(times, through: 119 * Self.tick) <= 4.5)
    }

    @Test func largeSeekPublishesOnTheSameTick() {
        // Two minutes on a 20-minute chapter is a 10% jump.
        let times = play(chapterSeconds: 20 * 60, seeks: [33: 120]).published
        #expect(times.contains(33 * Self.tick))
    }

    @Test func publishesWheneverThePerTickComparisonDid() {
        // A 60 s chapter moves 0.83% per tick, so the old per-tick rule fired
        // on every tick, and a reset to 0 (track change) fires it too.
        var player = Player()
        var position: TimeInterval = 0
        for i in 0..<100 {
            position += Self.tick
            if i == 50 { player.displayed = 0 }
            let oldRuleFires = abs(player.displayed - position / 60) > 0.005
            let fires = player.tick(fraction: position / 60, at: TimeInterval(i) * Self.tick)
            #expect(fires || !oldRuleFires, "tick \(i)")
        }
    }

    @Test func pausedSmallBackwardSeekPublishes() {
        // On a 20-minute chapter (threshold 6 s of audio), play so the last
        // publication trails the live position, pause, then skip back by an
        // amount that lands near that stale publication but is more than the
        // threshold from where the pause left the display.
        var player = Player()
        let chapter: TimeInterval = 20 * 60
        var position: TimeInterval = 60
        var wall: TimeInterval = 0
        for _ in 0..<7 {
            position += Self.tick
            _ = player.tick(fraction: position / chapter, at: wall)
            wall += Self.tick
        }
        // The pause refresh runs while paused; the pause itself publishes elsewhere.
        _ = player.tick(fraction: position / chapter, isPlaying: false, at: wall)
        position -= 7
        let fires = player.tick(fraction: position / chapter, isPlaying: false, at: wall + 1)
        #expect(fires)
    }

    @Test func pausedPositionDoesNotRepublishAsTimePasses() {
        var player = Player()
        let first = player.tick(fraction: 0.4, isPlaying: false, at: 0)
        #expect(first)
        for second in 1...60 {
            let fires = player.tick(fraction: 0.4, isPlaying: false, at: TimeInterval(second))
            #expect(!fires, "second \(second)")
        }
    }

    @Test func resetPublishesTheNextTickAtOnce() {
        var player = Player()
        _ = player.tick(fraction: 0.4, at: 0)
        let beforeReset = player.tick(fraction: 0.4, at: 1)
        #expect(!beforeReset)
        player.policy.reset()
        let afterReset = player.tick(fraction: 0.4, at: 1.5)
        #expect(afterReset)
    }
}
