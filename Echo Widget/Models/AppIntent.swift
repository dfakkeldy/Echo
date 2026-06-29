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
        // Widget extensions cannot import WatchConnectivity. The main app
        // handles watch communication when openAppWhenRun opens it.
        let defaults = AppGroupDefaults.shared
        let currentIsPlaying = defaults.bool(forKey: "isPlaying")
        defaults.set(!currentIsPlaying, forKey: "isPlaying")
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
