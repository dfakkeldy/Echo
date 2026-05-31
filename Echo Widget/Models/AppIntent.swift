import WidgetKit
import AppIntents

struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var openAppWhenRun: Bool = true

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
    static var title: LocalizedStringResource = "Create Bookmark"
    static var description = IntentDescription("Creates a new bookmark for the current audiobook position.")
    
    @Parameter(title: "Note")
    var note: String?

    func perform() async throws -> some IntentResult {
        let defaults = AppGroupDefaults.shared
        
        guard let folderKey = defaults.string(forKey: "folderKey"),
              let trackId = defaults.string(forKey: "trackId"),
              let currentTime = defaults.object(forKey: "currentTime") as? TimeInterval else {
            throw NSError(domain: "CreateBookmarkIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active audiobook found."])
        }

        let newBookmark = Bookmark(
            id: UUID(),
            title: "Bookmark \(Date().formatted(date: .omitted, time: .shortened))",
            folderKey: folderKey,
            trackId: trackId,
            timestamp: currentTime,
            note: note
        )

        let bookmarksKey = "bookmarks_\(folderKey)"
        var bookmarks = (try? JSONDecoder().decode([Bookmark].self, from: defaults.data(forKey: bookmarksKey) ?? Data())) ?? []
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
