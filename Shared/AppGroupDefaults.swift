import Foundation

/// Shared app-group UserDefaults accessor for iOS, watchOS, macOS, and Widget targets.
/// Provides a single source of truth for the suite name and migration logic.
public enum AppGroupDefaults {
    public static let suiteName = "group.com.echo.audiobooks"

    private static let migrationKey = "didMigrateWidgetDefaultsToAppGroup"

    public static var shared: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if DEBUG
            assertionFailure("Unable to open app-group UserDefaults suite: \(suiteName)")
            #endif
            return .standard
        }
        return defaults
    }

    public static func migrateStandardDefaultsIfNeeded() {
        guard let groupedDefaults = UserDefaults(suiteName: suiteName),
              !groupedDefaults.bool(forKey: migrationKey) else {
            return
        }

        let keys = [
            "isPlaying",
            "title",
            "progressFraction",
            "loopMode",
            "currentTime",
            "playbackSpeed",
            "bookmarkStorageKey",
            "folderKey",
            "trackId",
            "totalBookDuration",
            "thumbnailData"
        ]

        for key in keys {
            guard groupedDefaults.object(forKey: key) == nil,
                  let value = UserDefaults.standard.object(forKey: key) else {
                continue
            }
            groupedDefaults.set(value, forKey: key)
        }

        groupedDefaults.set(true, forKey: migrationKey)
    }
}

extension String {
    /// Truncates instances of the word "Chapter" to "Ch." if the provided setting is enabled.
    func applyingChapterTruncation(enabled: Bool) -> String {
        guard enabled else { return self }
        return self
            .replacingOccurrences(of: "Chapter ", with: "Ch. ", options: .caseInsensitive)
            .replacingOccurrences(of: "Chapter", with: "Ch.", options: .caseInsensitive)
    }
}
