// SPDX-License-Identifier: GPL-3.0-or-later
import AppIntents
import WidgetKit

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Playback"
    static let openAppWhenRun: Bool = true

    // Runs on the main actor: `AppGroupDefaults.shared` (a non-Sendable
    // `UserDefaults`) is main-actor-isolated under the project's default
    // isolation, so a nonisolated `perform()` cannot touch it (audit §3.1).
    // An `async` requirement may be witnessed by a `@MainActor` method.
    @MainActor
    func perform() async throws -> some IntentResult {
        // Widget extensions cannot import WatchConnectivity, so this intent
        // cannot toggle real playback itself. It records the desired state
        // for the watch app (which `openAppWhenRun` opens) to consume in
        // `refreshAfterWake` and forward to the phone as an absolute
        // play/pause command. The flag flip below is only the optimistic
        // card update; the app-group value is reconciled with the phone's
        // authoritative state as soon as the app pulls it.
        let defaults = AppGroupDefaults.shared
        let now = Date()
        let desiredIsPlaying = !defaults.bool(forKey: "isPlaying")
        WidgetPlaybackToggleRequest.write(
            desiredIsPlaying: desiredIsPlaying, at: now, to: defaults)
        defaults.set(desiredIsPlaying, forKey: "isPlaying")
        // Re-anchor the progress projection: when the flip starts playback,
        // projecting from a stale anchor would jump the bar forward.
        WatchWidgetProgressProjection.writeAnchor(now, to: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: "Echo_Widget")

        return .result()
    }
}

struct CreateBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Bookmark"
    static let description = IntentDescription(
        "Creates a new bookmark for the current audiobook position.")

    @Parameter(title: "Note")
    var note: String?

    // Main-actor isolated: reads `AppGroupDefaults.shared` and constructs a
    // main-actor `Bookmark`, neither reachable from a nonisolated `perform()`
    // (audit §3.1).
    @MainActor
    func perform() async throws -> some IntentResult {
        let defaults = AppGroupDefaults.shared

        // Read the PER-TRACK position the app publishes (`currentTrackTime`),
        // not the cumulative whole-book `currentTime` the watch context carries.
        // `Bookmark.timestamp` is a per-track offset, so on a multi-track book
        // the cumulative value would land the bookmark in the wrong place.
        guard let state = WidgetPlaybackStateStore.read(from: defaults) else {
            throw NSError(
                domain: "CreateBookmarkIntent", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No active audiobook found."])
        }

        let title = "Bookmark \(Date().formatted(date: .omitted, time: .shortened))"
        let newBookmark = WidgetPlaybackStateStore.bookmark(
            from: state, note: note, title: title)

        let bookmarksKey = "bookmarks_\(state.folderKey)"
        var bookmarks =
            (try? JSONDecoder().decode(
                [Bookmark].self, from: defaults.data(forKey: bookmarksKey) ?? Data())) ?? []
        bookmarks.append(newBookmark)

        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }

        return .result()
    }
}

struct BookmarkAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateBookmarkIntent(),
            phrases: [
                "Bookmark this in \(.applicationName)"
            ],
            shortTitle: "Create Bookmark",
            systemImageName: "bookmark"
        )
    }
}
