import Foundation
import GRDB
import os.log

/// One-shot migrator that reads existing UserDefaults/JSON-sidecar data
/// and writes it into the SQL database.
#if os(iOS)
    enum MigrationService {
        private static let logger = Logger(category: "Migration")

        /// Run the migration if needed. Safe to call on every launch.
        /// All writes are wrapped in a single transaction — partial failures roll back.
        static func migrateIfNeeded(database: DatabaseService) {
            guard !database.isMigrationDone else { return }

            logger.info("Starting UserDefaults → SQL migration…")

            let defaults = UserDefaults.standard

            do {
                try database.write { db in
                    // 1. Migrate bookmarks — iterate over all known bookmark keys.
                    let bookmarkKeys = defaults.dictionaryRepresentation().keys
                        .filter { $0.hasPrefix("bookmarks_") }
                    for key in bookmarkKeys {
                        let audiobookKey = String(key.dropFirst("bookmarks_".count))
                        guard let data = defaults.data(forKey: key),
                            let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
                        else { continue }

                        ensureAudiobookExists(id: audiobookKey, db: db)

                        let dao = BookmarkDAO(db: database.writer)
                        for bm in bookmarks {
                            // Insert within THIS transaction (BookmarkDAO.insert
                            // would open a nested write on the same writer) and
                            // ignore duplicates so a re-run can't wedge the
                            // one-shot migration forever (§5.10).
                            try dao.insert(BookmarkRecord(from: bm), in: db)
                        }
                        logger.debug("Migrated \(bookmarks.count) bookmarks for \(audiobookKey)")
                    }

                    // 2. Migrate playback progress.
                    let progressKey = "EchoAudiobooks.progress.dictionary"
                    if let progress = defaults.dictionary(forKey: progressKey)
                        as? [String: [String: Any]]
                    {
                        for (audiobookID, item) in progress {
                            guard item["trackId"] as? String != nil,
                                let time = item["time"] as? Double
                            else { continue }

                            ensureAudiobookExists(id: audiobookID, db: db)

                            try db.execute(
                                sql: """
                                    INSERT OR REPLACE INTO playback_state (audiobook_id, last_position, speed)
                                    VALUES (?, ?, 1.0)
                                    """,
                                arguments: [audiobookID, time]
                            )
                        }
                    }

                    // 3. Migrate per-book speed.
                    let speedKey = "EchoAudiobooks.playback.speed.dictionary"
                    if let speeds = defaults.dictionary(forKey: speedKey) as? [String: Double] {
                        for (audiobookID, speed) in speeds {
                            ensureAudiobookExists(id: audiobookID, db: db)

                            try db.execute(
                                sql: "UPDATE playback_state SET speed = ? WHERE audiobook_id = ?",
                                arguments: [speed, audiobookID]
                            )
                        }
                    }

                    // 4. Migrate settings.
                    let settingsKeys = [
                        "appFont", "isDarkMode", "playBookmarksInline",
                        "chapterCueEnabled", "bookmarkCueEnabled",
                        "selectedChapterCue", "selectedBookmarkCue",
                    ]
                    for key in settingsKeys {
                        if let value = defaults.string(forKey: key) {
                            try db.execute(
                                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                                arguments: [key, value]
                            )
                        }
                    }
                }

                database.isMigrationDone = true
                logger.info("Migration complete.")

            } catch {
                logger.error("Migration failed — rolled back: \(error.localizedDescription)")
                // Leave isMigrationDone false so it retries next launch.
            }
        }

        /// Inserts a skeleton audiobook record if it does not already exist,
        /// preventing foreign key constraint violations. Must be called within a write transaction.
        private static func ensureAudiobookExists(id: String, db: Database) {
            let title =
                URL(string: id)?.deletingPathExtension().lastPathComponent ?? "Migrated Audiobook"
            do {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO audiobook (id, title, duration, added_at)
                        VALUES (?, ?, 0, ?)
                        """,
                    arguments: [id, title, Date().ISO8601Format()]
                )
            } catch {
                logger.error(
                    "Failed to ensure audiobook \(id) exists: \(error.localizedDescription)")
            }
        }
    }
#endif
