// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the widget → watch-app play/pause handshake.
///
/// Regression under test: `TogglePlaybackIntent` used to flip the app group's
/// `isPlaying` flag and stop — nothing consumed the flip, so the card changed
/// while real playback did not, desyncing the two on the first tap. The
/// handshake records the *desired absolute state* for the watch app to
/// forward to the phone; absolute play/pause stays correct even if an
/// authoritative state push lands between the tap and consumption.
struct WidgetPlaybackToggleRequestTests {

    /// A throwaway suite so tests never read or mutate the real app group.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "test.widgettogglerequest.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh request returns the desired state and clears itself")
    func freshRequestConsumes() {
        let defaults = makeDefaults("fresh")
        let tap = Date(timeIntervalSinceReferenceDate: 1_000_000)
        WidgetPlaybackToggleRequest.write(desiredIsPlaying: true, at: tap, to: defaults)

        let desired = WidgetPlaybackToggleRequest.consume(
            from: defaults, at: tap.addingTimeInterval(2))
        #expect(desired == true)
        // One tap, one command: a second consume must find nothing.
        #expect(
            WidgetPlaybackToggleRequest.consume(from: defaults, at: tap.addingTimeInterval(3))
                == nil)
    }

    @Test("a stale request is discarded — acting on an old tap fights the user")
    func staleRequestDiscarded() {
        let defaults = makeDefaults("stale")
        let tap = Date(timeIntervalSinceReferenceDate: 1_000_000)
        WidgetPlaybackToggleRequest.write(desiredIsPlaying: false, at: tap, to: defaults)

        let consumedAt = tap.addingTimeInterval(WidgetPlaybackToggleRequest.freshnessWindow + 1)
        #expect(WidgetPlaybackToggleRequest.consume(from: defaults, at: consumedAt) == nil)
        // Discarding must still clear: the request must never fire later.
        #expect(defaults.object(forKey: WidgetPlaybackToggleRequest.Key.requestDate) == nil)
        #expect(defaults.object(forKey: WidgetPlaybackToggleRequest.Key.desiredIsPlaying) == nil)
    }

    @Test("a request stamped in the future (clock skew) is discarded")
    func futureStampDiscarded() {
        let defaults = makeDefaults("future")
        let tap = Date(timeIntervalSinceReferenceDate: 1_000_000)
        WidgetPlaybackToggleRequest.write(desiredIsPlaying: true, at: tap, to: defaults)

        #expect(
            WidgetPlaybackToggleRequest.consume(
                from: defaults, at: tap.addingTimeInterval(-5)) == nil)
    }

    @Test("no request and a partial request both read as nil")
    func absentOrPartialRequestIsNil() {
        let empty = makeDefaults("empty")
        #expect(WidgetPlaybackToggleRequest.consume(from: empty, at: Date()) == nil)

        let partial = makeDefaults("partial")
        WidgetPlaybackToggleRequest.write(desiredIsPlaying: true, at: Date(), to: partial)
        partial.removeObject(forKey: WidgetPlaybackToggleRequest.Key.desiredIsPlaying)
        #expect(WidgetPlaybackToggleRequest.consume(from: partial, at: Date()) == nil)
    }
}
