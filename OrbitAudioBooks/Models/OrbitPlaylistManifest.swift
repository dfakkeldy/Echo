import Foundation

/// A portable manifest stored as `.orbitplaylist.json` in a playlist folder,
/// consolidating track metadata, playback state, and bookmarks that were
/// previously scattered across UserDefaults keys.
struct OrbitPlaylistManifest: Codable {
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
