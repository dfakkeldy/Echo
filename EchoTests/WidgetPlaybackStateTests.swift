// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the app-group mirror that the home-screen widget and the
/// "Bookmark this in Echo" Siri / App Intent read.
///
/// Regression under test: on a *multi-track* book the bookmark the intent
/// creates must use the PER-TRACK offset (what `Bookmark.timestamp` stores),
/// not the cumulative whole-book time the watch context publishes under
/// `currentTime`. The two are equal only for single-track books, which is why
/// the original bug landed bookmarks at the wrong spot on multi-track books
/// while looking fine on single-track ones.
struct WidgetPlaybackStateTests {

    /// A throwaway suite so tests never read or mutate the real app group.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "test.widgetplaybackstate.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("multi-track bookmark uses the per-track offset, not cumulative book time")
    func multiTrackBookmarkUsesPerTrackOffset() throws {
        let defaults = makeDefaults("multitrack")
        // The listener is 30s into track 3; the cumulative book time here would
        // be ~3630s. The bookmark must record 30 — the per-track offset.
        WidgetPlaybackStateStore.write(
            WidgetPlaybackState(folderKey: "/books/dune", trackId: "track-3", perTrackTime: 30),
            to: defaults)

        let state = try #require(WidgetPlaybackStateStore.read(from: defaults))
        let bookmark = WidgetPlaybackStateStore.bookmark(
            from: state, note: "spice", title: "Bookmark")

        #expect(bookmark.timestamp == 30)
        #expect(bookmark.trackId == "track-3")
        #expect(bookmark.folderKey == "/books/dune")
        #expect(bookmark.note == "spice")
    }

    @Test("single-track bookmark still records its position")
    func singleTrackBookmarkRecordsPosition() throws {
        let defaults = makeDefaults("singletrack")
        WidgetPlaybackStateStore.write(
            WidgetPlaybackState(folderKey: "/books/solo.m4b", trackId: "solo", perTrackTime: 95.5),
            to: defaults)

        let state = try #require(WidgetPlaybackStateStore.read(from: defaults))
        #expect(state.perTrackTime == 95.5)
        #expect(state.trackId == "solo")
    }

    @Test("read returns nil when no active book has been published")
    func readNilWhenNothingPublished() {
        let defaults = makeDefaults("absent")
        #expect(WidgetPlaybackStateStore.read(from: defaults) == nil)
    }

    @Test("read returns nil when only some keys are present")
    func readNilWhenPartiallyPublished() {
        let defaults = makeDefaults("partial")
        defaults.set("/books/dune", forKey: "folderKey")
        // trackId and currentTrackTime intentionally missing.
        #expect(WidgetPlaybackStateStore.read(from: defaults) == nil)
    }

    @Test("writing nil clears a previously published book")
    func writeNilClearsPublishedBook() {
        let defaults = makeDefaults("clear")
        WidgetPlaybackStateStore.write(
            WidgetPlaybackState(folderKey: "/b", trackId: "t", perTrackTime: 5),
            to: defaults)
        WidgetPlaybackStateStore.write(nil, to: defaults)
        #expect(WidgetPlaybackStateStore.read(from: defaults) == nil)
    }

    @Test("per-track time is read from its own key, never the watch's cumulative currentTime")
    func perTrackKeyDistinctFromCumulative() throws {
        let defaults = makeDefaults("distinct")
        // Simulate the watch context having written a cumulative book time.
        defaults.set(3630.0, forKey: "currentTime")
        WidgetPlaybackStateStore.write(
            WidgetPlaybackState(folderKey: "/books/dune", trackId: "track-3", perTrackTime: 30),
            to: defaults)

        let state = try #require(WidgetPlaybackStateStore.read(from: defaults))
        // The store must read its own per-track key, never the cumulative one.
        #expect(state.perTrackTime == 30)
        // The legacy cumulative key is left untouched for the watch.
        #expect(defaults.double(forKey: "currentTime") == 3630.0)
    }
}
