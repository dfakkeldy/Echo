import Foundation
import os.log

/// UserDefaults-backed persistence for book progress, bookmarks, speed,
/// ordering, and security-scoped bookmark restoration.
struct Persistence {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "OrbitAudiobooks.selection.bookmark"
    private let progressKey = "OrbitAudiobooks.progress.dictionary"
    private let speedKey = "OrbitAudiobooks.playback.speed.dictionary"
    private let loopModeKey = "OrbitAudiobooks.playback.loopMode.dictionary"
    private let lastTrackKey = "OrbitAudiobooks.lastTrack.dictionary"

    // MARK: - Track / Speed / Loop Persistence

    func saveLastTrack(for folderKey: String, trackId: String) {
        var dict = defaults.dictionary(forKey: lastTrackKey) as? [String: String] ?? [:]
        dict[folderKey] = trackId
        defaults.set(dict, forKey: lastTrackKey)
    }

    func getLastTrack(for folderKey: String) -> String? {
        let dict = defaults.dictionary(forKey: lastTrackKey) as? [String: String] ?? [:]
        return dict[folderKey]
    }

    func saveSpeed(for title: String, speed: Float) {
        var dict = defaults.dictionary(forKey: speedKey) as? [String: Double] ?? [:]
        dict[title] = Double(speed)
        defaults.set(dict, forKey: speedKey)
    }

    func getSpeed(for title: String) -> Float? {
        let dict = defaults.dictionary(forKey: speedKey) as? [String: Double] ?? [:]
        return dict[title].map { Float($0) }
    }

    func saveLoopMode(for key: String, loopMode: String) {
        var dict = defaults.dictionary(forKey: loopModeKey) as? [String: String] ?? [:]
        dict[key] = loopMode
        defaults.set(dict, forKey: loopModeKey)
    }

    func getLoopMode(for key: String) -> String? {
        let dict = defaults.dictionary(forKey: loopModeKey) as? [String: String] ?? [:]
        return dict[key]
    }

    // MARK: - Order & Enabled State

    func saveOrder(for key: String, ids: [String]) {
        defaults.set(ids, forKey: "order_\(key)")
    }

    func loadOrder(for key: String) -> [String]? {
        defaults.stringArray(forKey: "order_\(key)")
    }

    func saveEnabledState(for key: String, states: [String: Bool]) {
        defaults.set(states, forKey: "enabled_\(key)")
    }

    func loadEnabledState(for key: String) -> [String: Bool]? {
        defaults.dictionary(forKey: "enabled_\(key)") as? [String: Bool]
    }

    // MARK: - Book Progress

    func saveBookProgress(for folderKey: String, trackId: String, time: Double) {
        var dict = defaults.dictionary(forKey: progressKey) as? [String: [String: Any]] ?? [:]
        dict[folderKey] = ["trackId": trackId, "time": time]
        defaults.set(dict, forKey: progressKey)
    }

    func getBookProgress(for folderKey: String) -> (trackId: String, time: Double)? {
        let dict = defaults.dictionary(forKey: progressKey) as? [String: [String: Any]] ?? [:]
        if let item = dict[folderKey], let trackId = item["trackId"] as? String, let time = item["time"] as? Double {
            return (trackId, time)
        }
        return nil
    }

    // MARK: - Security-Scoped Bookmark

    func saveBookmark(url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: bookmarkKey)
        } catch {
            print("Bookmark save failed: \(error)")
        }
    }

    func restoreBookmark() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }

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
            print("Bookmark restore failed: \(error)")
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
            print("Bookmark encode failed: \(error)")
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
