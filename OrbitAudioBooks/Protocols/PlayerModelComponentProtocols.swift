import Foundation

// MARK: - PlaybackTimelineItem

/// Items that appear on the playlist (relative-time) timeline.
/// Exposes only relative-time fields — no Date or calendar concepts.
/// Future video chapter markers conform to this for unified timeline rendering.
protocol PlaybackTimelineItem: Identifiable {
    var mediaTimestamp: TimeInterval? { get }
    var title: String { get }
    var cardType: ContentCardType { get }
}

// MARK: - BookmarkStoreProtocol

@MainActor protocol BookmarkStoreProtocol {
    var bookmarks: [Bookmark] { get }
    @discardableResult
    func addBookmark(at time: TimeInterval, trackId: String?, folderKey: String?) -> Bookmark
    func deleteBookmark(id: UUID, folderURL: URL?)
    func updateBookmark(id: UUID, title: String, timestamp: TimeInterval, note: String?,
                        voiceMemoFileName: String?, bookmarkImageFileName: String?)
}

// MARK: - PlaybackControllerProtocol

@MainActor protocol PlaybackControllerProtocol {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var speed: Float { get set }
    func play()
    func pause()
    func togglePlayPause()
    @discardableResult func skipForward30() -> Bool
    @discardableResult func skipBackward30() -> Bool
    func seek(to time: TimeInterval, completion: ((Bool) -> Void)?)
    func nextChapter()
    func previousChapterOrRestart()
}

// MARK: - SleepTimerManagerProtocol

@MainActor protocol SleepTimerManagerProtocol {
    var mode: SleepTimerMode { get }
    var remainingSeconds: Int { get }
    func setTimer(_ mode: SleepTimerMode)
    func cancel()
}
