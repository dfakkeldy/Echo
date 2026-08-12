// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Watch Widget Progress Projection

/// Projects the whole-book progress bar forward in wall-clock time so the
/// watch Smart Stack widget keeps moving between deliveries of fresh state.
///
/// The watch app persists an *anchor* — the last authoritative
/// `totalProgressFraction` it applied plus the wall-clock date it applied it —
/// alongside the playback speed and total book duration the phone already
/// syncs. While the book is playing, the widget renders
/// `anchor + elapsedWallClock × speed ÷ bookDuration` at any future entry date
/// instead of freezing at the last written fraction. WidgetKit renders
/// pre-scheduled timeline entries without spending refresh budget, so a
/// timeline of projected entries stays live even while the watch app is
/// suspended and no reloads are granted.
///
/// The projection deliberately stops `projectionHorizon` past the anchor: if
/// no fresh state has arrived for that long, the phone may have stopped
/// playing without the watch hearing about it, and freezing is more honest
/// than running the bar to 100%.
///
/// `nonisolated` (like `WidgetPlaybackStateStore`): pure value math over an
/// injected `UserDefaults`, callable from any isolation in every target the
/// `Shared` folder compiles into.
nonisolated struct WatchWidgetProgressProjection: Equatable {
    enum Key {
        /// Wall-clock date (`timeIntervalSinceReferenceDate`) at which
        /// `totalProgressFraction` was last written from authoritative state.
        static let anchorDate = "totalProgressAnchorDate"
    }

    /// Spacing between projected timeline entries. Two minutes moves a
    /// multi-hour book's bar by well under a percent per entry — smooth at
    /// widget scale without inflating the timeline.
    static let entryStride: TimeInterval = 120

    /// How far past the anchor the projection is trusted before freezing.
    static let projectionHorizon: TimeInterval = 3 * 60 * 60

    /// Upper bound on scheduled entries per timeline (2 hours at
    /// `entryStride`); the refresh policy re-runs the provider afterwards.
    static let maxTimelineEntries = 60

    var anchorDate: Date?
    var anchorFraction: Double
    var isPlaying: Bool
    var playbackSpeed: Double
    var totalBookDuration: TimeInterval

    /// The fraction to render at `date`. Falls back to the anchored fraction
    /// whenever projection is impossible (paused, no anchor, no duration) or
    /// meaningless (clock skew, anchor beyond the trust horizon).
    func fraction(at date: Date) -> Double {
        let anchored = Self.clamped(anchorFraction)
        guard isPlaying, let anchorDate, totalBookDuration > 0 else { return anchored }
        let elapsed = date.timeIntervalSince(anchorDate)
        guard elapsed > 0 else { return anchored }
        let speed = playbackSpeed > 0 ? playbackSpeed : 1.0
        let projected =
            anchorFraction + min(elapsed, Self.projectionHorizon) * speed / totalBookDuration
        return Self.clamped(projected)
    }

    /// Entry dates for a projected timeline starting at `now`. Paused (or
    /// unprojectable) state yields the single static entry the widget always
    /// rendered; playing state yields entries every `entryStride` until the
    /// book ends, the trust horizon passes, or the entry cap is reached.
    func timelineDates(startingAt now: Date) -> [Date] {
        guard isPlaying, let anchorDate, totalBookDuration > 0 else { return [now] }
        var dates = [now]
        let horizonEnd = anchorDate.addingTimeInterval(Self.projectionHorizon)
        var next = now.addingTimeInterval(Self.entryStride)
        while dates.count < Self.maxTimelineEntries, next <= horizonEnd {
            dates.append(next)
            if fraction(at: next) >= 1 { break }
            next = next.addingTimeInterval(Self.entryStride)
        }
        return dates
    }

    /// Reads the projection inputs the watch app persists into the widget's
    /// app group. The non-anchor keys mirror `WatchViewModel.applyState`.
    static func read(from defaults: UserDefaults) -> WatchWidgetProgressProjection {
        let anchor = (defaults.object(forKey: Key.anchorDate) as? Double)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
        return WatchWidgetProgressProjection(
            anchorDate: anchor,
            anchorFraction: defaults.double(forKey: "totalProgressFraction"),
            isPlaying: defaults.bool(forKey: "isPlaying"),
            playbackSpeed: defaults.double(forKey: "playbackSpeed"),
            totalBookDuration: defaults.double(forKey: "totalBookDuration"))
    }

    /// Stamps the anchor after authoritative state lands. Call alongside every
    /// `totalProgressFraction` write.
    static func writeAnchor(_ date: Date, to defaults: UserDefaults) {
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Key.anchorDate)
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }
}
