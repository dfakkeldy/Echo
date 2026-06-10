import Foundation

/// A portable manifest stored as `.echoplaylist.json` in a playlist folder,
/// consolidating track metadata, playback state, and bookmarks that were
/// previously scattered across UserDefaults keys.
struct EchoPlaylistManifest: Codable, Sendable {
    var version: Int = 1
    var title: String?
    var author: String?
    var tracks: [ManifestTrack]
    var playbackState: ManifestPlaybackState
    var bookmarks: [ManifestBookmark]?

    struct ManifestTrack: Codable {
        var file: String
        var title: String?
        var duration: Double?
        var enabled: Bool = true
    }

    struct ManifestPlaybackState: Codable {
        var lastTrackId: String?
        var lastPosition: Double = 0
        var speed: Double = 1.25
        var loopMode: String = "off"
    }

    struct ManifestBookmark: Codable {
        var id: String
        var title: String
        var timestamp: Double
        var trackId: String?
        var note: String?
    }
}

// MARK: - Custom Decodable (default-value resilience)

extension EchoPlaylistManifest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        tracks = try c.decode([ManifestTrack].self, forKey: .tracks)
        playbackState = try c.decode(ManifestPlaybackState.self, forKey: .playbackState)
        bookmarks = try c.decodeIfPresent([ManifestBookmark].self, forKey: .bookmarks)
    }
}

extension EchoPlaylistManifest.ManifestTrack {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

extension EchoPlaylistManifest.ManifestPlaybackState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastTrackId = try c.decodeIfPresent(String.self, forKey: .lastTrackId)
        lastPosition = try c.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.25
        loopMode = try c.decodeIfPresent(String.self, forKey: .loopMode) ?? "off"
    }
}
