import Foundation
import GRDB
import os.log

/// One-shot migrator that reads existing UserDefaults/JSON-sidecar data
/// and writes it into the SQL database.
#if os(iOS) || os(macOS)
enum MigrationService {
    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "Migration")

    /// Run the migration if needed. Safe to call on every launch.
    static func migrateIfNeeded(database: DatabaseService) {
        guard !database.isMigrationDone else { return }

        logger.info("Starting UserDefaults → SQL migration…")

        do {
            let defaults = UserDefaults.standard

            // 1. Migrate bookmarks — iterate over all known bookmark keys.
            let bookmarkKeys = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("bookmarks_") }
            for key in bookmarkKeys {
                let audiobookKey = String(key.dropFirst("bookmarks_".count))
                guard let data = defaults.data(forKey: key),
                      let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
                else { continue }

                let dao = BookmarkDAO(db: database.writer)
                for bm in bookmarks {
                    let record = BookmarkRecord(from: bm)
                    try? dao.insert(record)
                }
                logger.debug("Migrated \(bookmarks.count) bookmarks for \(audiobookKey)")
            }

            // 2. Migrate playback progress.
            let progressKey = "OrbitAudiobooks.progress.dictionary"
            if let progress = defaults.dictionary(forKey: progressKey) as? [String: [String: Any]] {
                for (audiobookID, item) in progress {
                    guard let _ = item["trackId"] as? String,
                          let time = item["time"] as? Double
                    else { continue }
                    try? database.write { db in
                        try db.execute(
                            sql: """
                                INSERT OR REPLACE INTO playback_state (audiobook_id, last_position, speed)
                                VALUES (?, ?, 1.0)
                                """,
                            arguments: [audiobookID, time]
                        )
                    }
                }
            }

            // 3. Migrate per-book speed.
            let speedKey = "OrbitAudiobooks.playback.speed.dictionary"
            if let speeds = defaults.dictionary(forKey: speedKey) as? [String: Double] {
                for (audiobookID, speed) in speeds {
                    try? database.write { db in
                        try db.execute(
                            sql: "UPDATE playback_state SET speed = ? WHERE audiobook_id = ?",
                            arguments: [speed, audiobookID]
                        )
                    }
                }
            }

            // 4. Migrate settings.
            let settingsKeys = [
                "appFont", "isDarkMode", "playBookmarksInline",
                "chapterCueEnabled", "bookmarkCueEnabled",
                "selectedChapterCue", "selectedBookmarkCue"
            ]
            let settingsDAO = SettingsDAO(db: database.writer)
            for key in settingsKeys {
                if let value = defaults.string(forKey: key) {
                    try? settingsDAO.set(key, value: value)
                }
            }

            database.isMigrationDone = true
            logger.info("Migration complete.")

        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            // Leave isMigrationDone false so it retries next launch.
        }
    }
}
#endif
