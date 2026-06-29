// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Widget / Siri Playback Mirror

/// The minimal slice of live playback state the home-screen widget and the
/// "Bookmark this in Echo" Siri / App Intent read from the shared app group.
///
/// `perTrackTime` is the offset *within the current track* — the same value
/// `Bookmark.timestamp` stores and the in-app `addBookmarkAtCurrentTime()`
/// records (`audioEngine.currentTime`). It is deliberately separate from the
/// cumulative whole-book time the watch context publishes under the legacy
/// `currentTime` key (`WatchStateContextBuilder`). For a multi-track book those
/// two values differ, and using the cumulative one drops a widget/Siri bookmark
/// at the wrong spot — and relative to the wrong track.
///
/// `nonisolated` (like `Bookmark`): a pure value model with no main-actor state,
/// so it stays callable from any isolation across every target the `Shared`
/// folder compiles into.
nonisolated struct WidgetPlaybackState: Equatable {
    var folderKey: String
    var trackId: String
    var perTrackTime: TimeInterval

    init(folderKey: String, trackId: String, perTrackTime: TimeInterval) {
        self.folderKey = folderKey
        self.trackId = trackId
        self.perTrackTime = perTrackTime
    }
}

/// Reads and writes ``WidgetPlaybackState`` in an app-group `UserDefaults`.
///
/// The `UserDefaults` is injected (rather than reaching for
/// `AppGroupDefaults.shared` internally) so the round-trip is unit-testable
/// against a throwaway suite — the same concrete-seam pattern as
/// `DatabaseService(inMemory:)`.
nonisolated enum WidgetPlaybackStateStore {
    enum Key {
        static let folderKey = "folderKey"
        static let trackId = "trackId"
        /// Per-track offset for bookmark creation. Distinct from the legacy
        /// `currentTime` key, which carries the cumulative whole-book time the
        /// watch UI needs.
        static let perTrackTime = "currentTrackTime"
    }

    /// Mirrors the live per-track position into the app group so the widget and
    /// Siri intent act on a fresh position. Passing `nil` clears the keys so a
    /// stale, no-longer-open book can't be bookmarked.
    static func write(_ state: WidgetPlaybackState?, to defaults: UserDefaults) {
        guard let state else {
            defaults.removeObject(forKey: Key.folderKey)
            defaults.removeObject(forKey: Key.trackId)
            defaults.removeObject(forKey: Key.perTrackTime)
            return
        }
        defaults.set(state.folderKey, forKey: Key.folderKey)
        defaults.set(state.trackId, forKey: Key.trackId)
        defaults.set(state.perTrackTime, forKey: Key.perTrackTime)
    }

    /// Reconstructs the published state, or `nil` if no book is currently
    /// published (any required key missing).
    static func read(from defaults: UserDefaults) -> WidgetPlaybackState? {
        guard let folderKey = defaults.string(forKey: Key.folderKey),
            let trackId = defaults.string(forKey: Key.trackId),
            let perTrackTime = defaults.object(forKey: Key.perTrackTime) as? TimeInterval
        else { return nil }
        return WidgetPlaybackState(
            folderKey: folderKey, trackId: trackId, perTrackTime: perTrackTime)
    }

    /// Builds the bookmark the "Bookmark this in Echo" intent appends. The
    /// timestamp is the PER-TRACK offset, matching `Bookmark.timestamp`'s
    /// contract and the in-app bookmark path.
    static func bookmark(
        from state: WidgetPlaybackState, note: String?, title: String
    ) -> Bookmark {
        Bookmark(
            id: UUID(),
            title: title,
            folderKey: state.folderKey,
            trackId: state.trackId,
            timestamp: state.perTrackTime,
            note: note
        )
    }
}
