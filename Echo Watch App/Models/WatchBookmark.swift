import Foundation

/// A lightweight bookmark representation used by the watch app to track
/// bookmarks the user has queued during the current session. The audio
/// file reference is intentionally `Optional` so that quick, generic
/// bookmarks can be created without invoking the microphone.
struct WatchBookmark: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var timestamp: TimeInterval
    var createdAt: Date
    /// Optional local audio file URL. When `nil`, this is a "quick" bookmark
    /// created without a voice memo and the playback controls should not be
    /// rendered for its row.
    var audioURL: URL?

    var hasAudio: Bool { audioURL != nil }

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: TimeInterval,
        createdAt: Date = Date(),
        audioURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.audioURL = audioURL
    }
}
