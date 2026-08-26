// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the wall-clock projection the watch Smart Stack widget uses to keep
/// its progress bar moving between deliveries of authoritative state.
///
/// Regression under test: the widget used to render a single static timeline
/// entry from the last app-group write and ask WidgetKit for a reload every
/// 60 s — far over the refresh budget, so the system throttled it and the
/// card froze at whatever progress was current the last time the watch app
/// ran. The projection lets pre-scheduled entries carry the bar forward.
struct WatchWidgetProgressProjectionTests {

    /// A throwaway suite so tests never read or mutate the real app group.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "test.watchwidgetprojection.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeProjection(
        anchorDate: Date? = Date(timeIntervalSinceReferenceDate: 1_000_000),
        anchorFraction: Double = 0.5,
        isPlaying: Bool = true,
        playbackSpeed: Double = 1.0,
        totalBookDuration: TimeInterval = 3600
    ) -> WatchWidgetProgressProjection {
        WatchWidgetProgressProjection(
            anchorDate: anchorDate, anchorFraction: anchorFraction, isPlaying: isPlaying,
            playbackSpeed: playbackSpeed, totalBookDuration: totalBookDuration)
    }

    // MARK: Fraction projection

    @Test("playing projects forward by wall clock × speed ÷ duration")
    func playingProjectsForward() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: anchor, playbackSpeed: 2.0)

        // 60 s of wall clock at 2× through a 3600 s book = +120/3600.
        let projected = p.fraction(at: anchor.addingTimeInterval(60))
        #expect(abs(projected - (0.5 + 120.0 / 3600.0)) < 0.0001)
    }

    @Test("paused stays at the anchored fraction")
    func pausedFreezes() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: anchor, isPlaying: false)
        #expect(p.fraction(at: anchor.addingTimeInterval(600)) == 0.5)
    }

    @Test("no anchor, no duration, and clock skew all freeze at the anchor")
    func unprojectableInputsFreeze() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let later = anchor.addingTimeInterval(600)

        #expect(makeProjection(anchorDate: nil).fraction(at: later) == 0.5)
        #expect(makeProjection(totalBookDuration: 0).fraction(at: later) == 0.5)
        // An entry date before the anchor (clock skew) must not project.
        #expect(makeProjection().fraction(at: anchor.addingTimeInterval(-60)) == 0.5)
    }

    @Test("a missing or zero speed projects at realtime instead of freezing")
    func zeroSpeedProjectsAtRealtime() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: anchor, playbackSpeed: 0)
        let projected = p.fraction(at: anchor.addingTimeInterval(360))
        #expect(abs(projected - (0.5 + 360.0 / 3600.0)) < 0.0001)
    }

    @Test("projection clamps at 1.0 and normalizes an out-of-range anchor")
    func clamping() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let nearEnd = makeProjection(anchorDate: anchor, anchorFraction: 0.999)
        #expect(nearEnd.fraction(at: anchor.addingTimeInterval(600)) == 1.0)

        let corrupt = makeProjection(anchorDate: anchor, anchorFraction: 1.4, isPlaying: false)
        #expect(corrupt.fraction(at: anchor) == 1.0)
    }

    @Test("projection freezes past the trust horizon instead of running to 100%")
    func horizonCapsProjection() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: anchor, anchorFraction: 0.1, totalBookDuration: 100_000)

        let atHorizon = p.fraction(
            at: anchor.addingTimeInterval(WatchWidgetProgressProjection.projectionHorizon))
        let wellPast = p.fraction(
            at: anchor.addingTimeInterval(WatchWidgetProgressProjection.projectionHorizon + 7200))
        #expect(atHorizon == wellPast)
        #expect(atHorizon < 1.0)
    }

    // MARK: Timeline schedule

    @Test("Projected entries respect WidgetKit's minimum recommended spacing")
    func projectedEntrySpacingRespectsWidgetKitBudget() {
        #expect(WatchWidgetProgressProjection.entryStride >= 5 * 60)
    }

    @Test("paused yields the single static entry the widget always rendered")
    func pausedTimelineIsSingleEntry() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: now, isPlaying: false)
        #expect(p.timelineDates(startingAt: now) == [now])
    }

    @Test("playing yields strided entries starting now, capped at the maximum")
    func playingTimelineStrides() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let p = makeProjection(anchorDate: now, anchorFraction: 0, totalBookDuration: 100_000)

        let dates = p.timelineDates(startingAt: now)
        #expect(dates.first == now)
        #expect(dates.count == WatchWidgetProgressProjection.maxTimelineEntries)
        #expect(
            dates[1].timeIntervalSince(dates[0]) == WatchWidgetProgressProjection.entryStride)
    }

    @Test("the schedule stops once a projected entry reaches the end of the book")
    func timelineStopsAtBookEnd() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // 3 minutes of book left: the bar hits 1.0 on the second stride.
        let p = makeProjection(anchorDate: now, anchorFraction: 0.9, totalBookDuration: 1800)

        let dates = p.timelineDates(startingAt: now)
        #expect(dates.count < WatchWidgetProgressProjection.maxTimelineEntries)
        #expect(p.fraction(at: dates.last!) == 1.0)
    }

    @Test("no entries are scheduled beyond the trust horizon")
    func timelineStopsAtHorizon() {
        let staleAnchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let now = staleAnchor.addingTimeInterval(
            WatchWidgetProgressProjection.projectionHorizon + 60)
        let p = makeProjection(
            anchorDate: staleAnchor, anchorFraction: 0.2, totalBookDuration: 100_000)

        // Already past the horizon: only the static "frozen" entry remains.
        #expect(p.timelineDates(startingAt: now) == [now])
    }

    // MARK: App-group round trip

    @Test("read(from:) rebuilds the projection the watch app persisted")
    func readRoundTrip() {
        let defaults = makeDefaults("roundtrip")
        let anchor = Date(timeIntervalSinceReferenceDate: 2_000_000)
        defaults.set(true, forKey: "isPlaying")
        defaults.set(0.25, forKey: "totalProgressFraction")
        defaults.set(1.5, forKey: "playbackSpeed")
        defaults.set(7200.0, forKey: "totalBookDuration")
        WatchWidgetProgressProjection.writeAnchor(anchor, to: defaults)

        let p = WatchWidgetProgressProjection.read(from: defaults)
        #expect(p.anchorDate == anchor)
        #expect(p.anchorFraction == 0.25)
        #expect(p.isPlaying)
        #expect(p.playbackSpeed == 1.5)
        #expect(p.totalBookDuration == 7200)
    }

    @Test("a missing anchor reads as nil and disables projection")
    func readMissingAnchor() {
        let defaults = makeDefaults("noanchor")
        defaults.set(true, forKey: "isPlaying")
        defaults.set(0.4, forKey: "totalProgressFraction")

        let p = WatchWidgetProgressProjection.read(from: defaults)
        #expect(p.anchorDate == nil)
        #expect(p.fraction(at: Date()) == 0.4)
    }
}
