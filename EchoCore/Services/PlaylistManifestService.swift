import Foundation

/// Reads, writes, and migrates `.echoplaylist.json` manifest files within
/// playlist folders. The manifest consolidates per-folder state (track order,
/// enabled states, speed, loop mode, playback progress, bookmarks) into a
/// single portable JSON file stored alongside the audio files.
struct PlaylistManifestService {

    static let fileName = ".echoplaylist.json"

    // MARK: - Read / Write

    static func read(from folderURL: URL) -> EchoPlaylistManifest? {
        let manifestURL = folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(EchoPlaylistManifest.self, from: data)
    }

    static func write(_ manifest: EchoPlaylistManifest, to folderURL: URL) {
        let manifestURL = folderURL.appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Migration

    /// Builds a manifest from existing UserDefaults data, preserving all
    /// per-folder state. Called once when a folder is opened and no manifest
    /// exists yet.
    static func migrate(
        from persistence: Persistence,
        folderURL: URL,
        tracks: [Track],
        bookmarks: [Bookmark],
        defaultSpeed: Float = 1.25
    ) -> EchoPlaylistManifest {
        let key = folderURL.absoluteString

        let manifestTracks = tracks.map { track in
            EchoPlaylistManifest.ManifestTrack(
                file: track.url.lastPathComponent,
                title: track.title,
                duration: nil,
                enabled: track.isEnabled
            )
        }

        let progress = persistence.getBookProgress(for: key)
        let speed = persistence.getSpeed(for: key) ?? defaultSpeed
        let loopMode = persistence.getLoopMode(for: key) ?? "off"

        let manifestBookmarks: [EchoPlaylistManifest.ManifestBookmark]? =
            bookmarks.isEmpty ? nil : bookmarks.map { bm in
                EchoPlaylistManifest.ManifestBookmark(
                    id: bm.id.uuidString,
                    title: bm.title,
                    timestamp: bm.timestamp,
                    trackId: bm.trackId,
                    note: bm.note
                )
            }

        return EchoPlaylistManifest(
            version: 1,
            title: folderURL.lastPathComponent,
            author: nil,
            tracks: manifestTracks,
            playbackState: EchoPlaylistManifest.ManifestPlaybackState(
                lastTrackId: progress?.trackId,
                lastPosition: progress?.time ?? 0,
                speed: Double(speed),
                loopMode: loopMode
            ),
            bookmarks: manifestBookmarks
        )
    }

    // MARK: - Targeted Updates

    static func updatePlaybackState(
        folderURL: URL,
        speed: Float? = nil,
        loopMode: String? = nil,
        lastTrackId: String? = nil,
        lastPosition: Double? = nil
    ) {
        guard var manifest = read(from: folderURL) else { return }
        if let s = speed { manifest.playbackState.speed = Double(s) }
        if let lm = loopMode { manifest.playbackState.loopMode = lm }
        if let lt = lastTrackId { manifest.playbackState.lastTrackId = lt }
        if let lp = lastPosition { manifest.playbackState.lastPosition = lp }
        write(manifest, to: folderURL)
    }

    static func updateTrackOrder(folderURL: URL, tracks: [Track]) {
        guard var manifest = read(from: folderURL) else { return }
        let orderedFiles = tracks.map(\.url.lastPathComponent)
        manifest.tracks.sort { a, b in
            let ai = orderedFiles.firstIndex(of: a.file) ?? Int.max
            let bi = orderedFiles.firstIndex(of: b.file) ?? Int.max
            return ai < bi
        }
        write(manifest, to: folderURL)
    }

    static func updateEnabledStates(folderURL: URL, states: [String: Bool]) {
        guard var manifest = read(from: folderURL) else { return }
        for i in manifest.tracks.indices {
            if let enabled = states[manifest.tracks[i].file] {
                manifest.tracks[i].enabled = enabled
            }
        }
        write(manifest, to: folderURL)
    }

    static func updateBookmarks(folderURL: URL, bookmarks: [Bookmark]) {
        guard var manifest = read(from: folderURL) else { return }
        manifest.bookmarks = bookmarks.isEmpty ? nil : bookmarks.map { bm in
            EchoPlaylistManifest.ManifestBookmark(
                id: bm.id.uuidString,
                title: bm.title,
                timestamp: bm.timestamp,
                trackId: bm.trackId,
                note: bm.note
            )
        }
        write(manifest, to: folderURL)
    }
}
