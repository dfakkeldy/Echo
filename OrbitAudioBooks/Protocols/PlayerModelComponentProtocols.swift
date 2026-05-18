import Foundation

// MARK: - BookmarkStoreProtocol

protocol BookmarkStoreProtocol {
    var bookmarks: [Bookmark] { get }
    @discardableResult
    func addBookmark(at time: TimeInterval, trackId: String?, folderKey: String?) -> Bookmark
    func deleteBookmark(id: UUID, folderURL: URL?)
    func updateBookmark(id: UUID, title: String, timestamp: TimeInterval, note: String?,
                        voiceMemoFileName: String?, bookmarkImageFileName: String?)
}

// MARK: - PlaybackControllerProtocol

protocol PlaybackControllerProtocol {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var speed: Float { get set }
    func play()
    func pause()
    func togglePlayPause()
    @discardableResult func skipForward30() -> Bool
    @discardableResult func skipBackward30() -> Bool
    func seek(to time: TimeInterval)
    func nextChapter()
    func previousChapterOrRestart()
}

// MARK: - SleepTimerManagerProtocol

protocol SleepTimerManagerProtocol {
    var mode: SleepTimerMode { get }
    var remainingSeconds: Int { get }
    func setTimer(_ mode: SleepTimerMode)
    func cancel()
}
