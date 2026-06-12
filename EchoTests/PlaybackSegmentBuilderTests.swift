import Testing
import Foundation
@testable import Echo

struct PlaybackSegmentBuilderTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private func opened(pos: TimeInterval = 100, speed: Double = 1.5, at: Date? = nil) -> RecorderEvent {
        .opened(audiobookID: "book1", trackID: "trk1", position: pos, speed: speed, source: "user", at: at ?? t0)
    }

    @Test func openedBeginsSegment() {
        var b = PlaybackSegmentBuilder()
        let actions = b.handle(opened())
        #expect(actions == [.begin(OpenSegment(
            audiobookID: "book1", trackID: "trk1", startedAt: t0,
            startPosition: 100, lastKnownPosition: 100, lastKnownAt: t0,
            speed: 1.5, source: "user"))])
        #expect(b.open != nil)
    }

    @Test func closedFinalizesAtGivenPosition() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let end = t0.addingTimeInterval(60)
        let actions = b.handle(.closed(position: 190, at: end))
        #expect(actions == [.finalize(endedAt: end, endPosition: 190)])
        #expect(b.open == nil)
    }

    @Test func closedWithNilPositionUsesLastKnown() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 150, at: t0.addingTimeInterval(50)))
        let end = t0.addingTimeInterval(60)
        let actions = b.handle(.closed(position: nil, at: end))
        #expect(actions == [.finalize(endedAt: end, endPosition: 150)])
    }

    @Test func shortSegmentIsDiscarded() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let actions = b.handle(.closed(position: 103, at: t0.addingTimeInterval(3)))
        #expect(actions == [.discard])
    }

    @Test func speedChangeSplitsSegment() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 160, at: t0.addingTimeInterval(40)))
        let at = t0.addingTimeInterval(41)
        let actions = b.handle(.speedChanged(newSpeed: 2.0, at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 160),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk1", startedAt: at,
                startPosition: 160, lastKnownPosition: 160, lastKnownAt: at,
                speed: 2.0, source: "user"))
        ])
    }

    @Test func seekSplitsAtPreSeekPosition() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 160, at: t0.addingTimeInterval(40)))
        let at = t0.addingTimeInterval(41)
        let actions = b.handle(.seeked(toPosition: 600, at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 160),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk1", startedAt: at,
                startPosition: 600, lastKnownPosition: 600, lastKnownAt: at,
                speed: 1.5, source: "user"))
        ])
    }

    @Test func reopenWhileOpenClosesPreviousFirst() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 200, at: t0.addingTimeInterval(100)))
        // Track auto-advance: play() fires opened again with the new track.
        let at = t0.addingTimeInterval(101)
        let actions = b.handle(.opened(audiobookID: "book1", trackID: "trk2", position: 0, speed: 1.5, source: "user", at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 200),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk2", startedAt: at,
                startPosition: 0, lastKnownPosition: 0, lastKnownAt: at,
                speed: 1.5, source: "user"))
        ])
    }

    @Test func heartbeatExtendsOpenSegment() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 145, at: t0.addingTimeInterval(30)))
        let actions = b.handle(.heartbeat(at: t0.addingTimeInterval(30)))
        #expect(actions == [.extendOpen(endedAt: t0.addingTimeInterval(30), endPosition: 145)])
    }

    @Test func eventsWithoutOpenSegmentAreNoOps() {
        var b = PlaybackSegmentBuilder()
        #expect(b.handle(.progressTick(position: 5, at: t0)).isEmpty)
        #expect(b.handle(.heartbeat(at: t0)).isEmpty)
        #expect(b.handle(.seeked(toPosition: 9, at: t0)).isEmpty)
        #expect(b.handle(.speedChanged(newSpeed: 2, at: t0)).isEmpty)
        #expect(b.handle(.closed(position: nil, at: t0)).isEmpty)
    }

    @Test func splitNeverDiscards() {
        // Splits chain segments; only explicit closes can produce micro-noise.
        // A 2-second-old segment split by a seek is still finalized, because
        // discarding it would punch a hole in continuous listening coverage.
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let actions = b.handle(.seeked(toPosition: 500, at: t0.addingTimeInterval(2)))
        #expect(actions.first == .finalize(endedAt: t0.addingTimeInterval(2), endPosition: 100))
    }
}
