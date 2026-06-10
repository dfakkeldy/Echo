import Foundation
import os.log

/// UserDefaults-backed persistence for book progress, bookmarks, speed,
/// ordering, and security-scoped bookmark restoration.
///
/// **Security note (§6.2):** Security-scoped bookmark data (binary plist) and
/// user-created bookmarks (JSON with private notes and audio memo metadata)
/// are stored in `UserDefaults.standard`, which is unencrypted on disk and
/// included in iCloud backups.  A future refactor should:
///
/// 1. Move security-scoped bookmark data (`bookmarkStore`) to Keychain
///    (`SecItemAdd` / `SecItemCopyMatching` with `kSecClassGenericPassword`).
/// 2. Move bookmark records with notes/voice-memo metadata to the App Group
///    SQLite store (already managed by GRDB) or to an encrypted Core Data
///    store with `FileProtectionType.complete`.
/// 3. Keep non-sensitive keys (progress, speed, ordering) in UserDefaults
///    but consider App Group `UserDefaults(suiteName:)` for consistency.
///
/// - SeeAlso: `DatabaseService` for the App Group SQLite database.
/// - SeeAlso: `AppGroupDefaults` for shared settings.
struct Persistence {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "EchoAudiobooks.selection.bookmark"

    // MARK: - Key generators (per-book — no cross-book collisions)

    private func progressKey(for folderKey: String) -> String { "EchoAudiobooks.progress.\(folderKey)" }
    private func speedKey(for title: String) -> String { "EchoAudiobooks.speed.\(title)" }
    private func loopModeKey(for key: String) -> String { "EchoAudiobooks.loopMode.\(key)" }
    private func lastTrackKey(for folderKey: String) -> String { "EchoAudiobooks.lastTrack.\(folderKey)" }
    private func pauseTimestampKey(for folderKey: String) -> String { "EchoAudiobooks.pauseTimestamp.\(folderKey)" }

    // Legacy dictionary key constants (used only for one-time migration).
    private let legacyProgressDictKey = "EchoAudiobooks.progress.dictionary"
    private let legacySpeedDictKey = "EchoAudiobooks.playback.speed.dictionary"
    private let legacyLoopModeDictKey = "EchoAudiobooks.playback.loopMode.dictionary"
    private let legacyLastTrackDictKey = "EchoAudiobooks.lastTrack.dictionary"
    private let legacyPauseTimestampDictKey = "EchoAudiobooks.pauseTimestamp.dictionary"

    // Migration flag: set once per legacy key after migration completes.
    private let migrationFlagPrefix = "EchoAudiobooks.migratedPerBook."

    // MARK: - Migration (one-time, safe to call on every read)

    /// Copies entries from a legacy dictionary key to per-book keys,
    /// then removes the legacy dictionary. Each legacy dict is keyed by
    /// book identifier; the value is moved as-is to `perBookKey(bookID)`.
    private func migrateIfNeeded(legacyKey: String, flagSuffix: String, to perBookKey: (String) -> String) {
        let flag = migrationFlagPrefix + flagSuffix
        guard !defaults.bool(forKey: flag) else { return }
        defer { defaults.set(true, forKey: flag) }

        guard let dict = defaults.dictionary(forKey: legacyKey) else { return }
        for (bookID, value) in dict {
            defaults.set(value, forKey: perBookKey(bookID))
        }
        defaults.removeObject(forKey: legacyKey)
    }

    // MARK: - Track / Speed / Loop Persistence

    func saveLastTrack(for folderKey: String, trackId: String, folderURL: URL? = nil) {
        defaults.set(trackId, forKey: lastTrackKey(for: folderKey))
        if let url = folderURL {
            PlaylistManifestService.updatePlaybackState(folderURL: url, lastTrackId: trackId)
        }
    }

    func getLastTrack(for folderKey: String, folderURL: URL? = nil) -> String? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            return manifest.playbackState.lastTrackId
        }
        migrateIfNeeded(legacyKey: legacyLastTrackDictKey, flagSuffix: "lastTrack", to: lastTrackKey(for:))
        return defaults.string(forKey: lastTrackKey(for: folderKey))
    }

    func saveSpeed(for title: String, speed: Float, folderURL: URL? = nil) {
        defaults.set(Double(speed), forKey: speedKey(for: title))
        if let url = folderURL {
            PlaylistManifestService.updatePlaybackState(folderURL: url, speed: speed)
        }
    }

    func getSpeed(for title: String, folderURL: URL? = nil) -> Float? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            return Float(manifest.playbackState.speed)
        }
        migrateIfNeeded(legacyKey: legacySpeedDictKey, flagSuffix: "speed", to: speedKey(for:))
        guard let value = defaults.object(forKey: speedKey(for: title)) as? Double else { return nil }
        return Float(value)
    }

    func saveLoopMode(for key: String, loopMode: String, folderURL: URL? = nil) {
        defaults.set(loopMode, forKey: loopModeKey(for: key))
        if let url = folderURL {
            PlaylistManifestService.updatePlaybackState(folderURL: url, loopMode: loopMode)
        }
    }

    func getLoopMode(for key: String, folderURL: URL? = nil) -> String? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            return manifest.playbackState.loopMode
        }
        migrateIfNeeded(legacyKey: legacyLoopModeDictKey, flagSuffix: "loopMode", to: loopModeKey(for:))
        return defaults.string(forKey: loopModeKey(for: key))
    }

    // MARK: - Order & Enabled State

    func saveOrder(for key: String, ids: [String], tracks: [Track]? = nil, folderURL: URL? = nil) {
        defaults.set(ids, forKey: "order_\(key)")
        if let url = folderURL, let tracks {
            PlaylistManifestService.updateTrackOrder(folderURL: url, tracks: tracks)
        }
    }

    func loadOrder(for key: String, folderURL: URL? = nil) -> [String]? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            return manifest.tracks.map(\.file)
        }
        return defaults.stringArray(forKey: "order_\(key)")
    }

    func saveEnabledState(for key: String, states: [String: Bool], folderURL: URL? = nil) {
        defaults.set(states, forKey: "enabled_\(key)")
        if let url = folderURL {
            PlaylistManifestService.updateEnabledStates(folderURL: url, states: states)
        }
    }

    func loadEnabledState(for key: String, folderURL: URL? = nil) -> [String: Bool]? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            return Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.file, $0.enabled) })
        }
        return defaults.dictionary(forKey: "enabled_\(key)") as? [String: Bool]
    }

    // MARK: - Book Progress

    func saveBookProgress(for folderKey: String, trackId: String, time: Double, folderURL: URL? = nil) {
        let item: [String: Any] = ["trackId": trackId, "time": time]
        defaults.set(item, forKey: progressKey(for: folderKey))
        if let url = folderURL {
            PlaylistManifestService.updatePlaybackState(folderURL: url, lastTrackId: trackId, lastPosition: time)
        }
    }

    func getBookProgress(for folderKey: String, folderURL: URL? = nil) -> (trackId: String, time: Double)? {
        if let url = folderURL,
           let manifest = PlaylistManifestService.read(from: url) {
            if let trackId = manifest.playbackState.lastTrackId {
                return (trackId, manifest.playbackState.lastPosition)
            }
            return nil
        }
        migrateIfNeeded(legacyKey: legacyProgressDictKey, flagSuffix: "progress", to: progressKey(for:))
        guard let item = defaults.dictionary(forKey: progressKey(for: folderKey)),
              let trackId = item["trackId"] as? String,
              let time = item["time"] as? Double else { return nil }
        return (trackId, time)
    }

    // MARK: - Pause Timestamp

    func savePauseTimestamp(_ timestamp: Date?, for folderKey: String) {
        if let timestamp {
            defaults.set(timestamp.timeIntervalSince1970, forKey: pauseTimestampKey(for: folderKey))
        } else {
            defaults.removeObject(forKey: pauseTimestampKey(for: folderKey))
        }
    }

    func getPauseTimestamp(for folderKey: String) -> Date? {
        migrateIfNeeded(legacyKey: legacyPauseTimestampDictKey, flagSuffix: "pauseTimestamp", to: pauseTimestampKey(for:))
        guard let interval = defaults.object(forKey: pauseTimestampKey(for: folderKey)) as? Double else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    // MARK: - Security-Scoped Bookmark

    /// Stores a security-scoped bookmark in the Keychain rather than
    /// unencrypted UserDefaults.  Security-scoped bookmark data grants
    /// file-system access to user-selected directories and must not be
    /// included in plaintext backups.  (§6.2)
    func saveBookmark(url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [],  // Full security-scoped bookmark survives app relaunch
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let success = KeychainStore.set(data, for: .securityScopedBookmark)
            if !success {
                os_log(.error, "Keychain save failed, falling back to UserDefaults for bookmark")
                defaults.set(data, forKey: bookmarkKey)
            } else {
                defaults.removeObject(forKey: bookmarkKey)
            }
        } catch {
            os_log(.error, "Bookmark save failed: %{private}@", error.localizedDescription)
        }
    }

    func restoreBookmark() -> URL? {
        // Migration: if Keychain is empty but UserDefaults has legacy data,
        // move it to Keychain and clean up the plaintext copy.  (§6.2)
        var data = KeychainStore.data(for: .securityScopedBookmark)
        if data == nil, let legacy = defaults.data(forKey: bookmarkKey) {
            let success = KeychainStore.set(legacy, for: .securityScopedBookmark)
            if success {
                defaults.removeObject(forKey: bookmarkKey)
            }
            data = legacy
        }
        guard let data else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveBookmark(url: url)
            }

            return url
        } catch {
            os_log(.error, "Bookmark restore failed: %{private}@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Bookmarks (Per-Book) Persistence

    private func bookmarksKey(for key: String) -> String { "bookmarks_\(key)" }

    func saveBookmarks(_ bookmarks: [Bookmark], for key: String, folderURL: URL? = nil) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(bookmarks)
        } catch {
            os_log(.error, "Bookmark encode failed: %{private}@", error.localizedDescription)
            return
        }

        if let folderURL {
            writeSidecar(data: data, folderURL: folderURL)
        }

        defaults.set(data, forKey: bookmarksKey(for: key))
    }

    func loadBookmarks(for key: String, folderURL: URL? = nil) -> [Bookmark] {
        if let folderURL,
           let bookmarks = readSidecar(folderURL: folderURL) {
            return bookmarks
        }

        let defaultsBookmarks: [Bookmark]
        if let data = defaults.data(forKey: bookmarksKey(for: key)),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            defaultsBookmarks = decoded
        } else {
            defaultsBookmarks = []
        }

        if let folderURL, !defaultsBookmarks.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(defaultsBookmarks) {
                writeSidecar(data: data, folderURL: folderURL)
            }
        }

        return defaultsBookmarks
    }

    private func writeSidecar(data: Data, folderURL: URL) {
        let sidecar = Bookmark.sidecarURL(for: folderURL)
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            os_log(.error, "Bookmark sidecar write failed: %{private}@", error.localizedDescription)
        }
    }

    private func readSidecar(folderURL: URL) -> [Bookmark]? {
        let sidecar = Bookmark.sidecarURL(for: folderURL)
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: sidecar.path),
              let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode([Bookmark].self, from: data)
    }
}
