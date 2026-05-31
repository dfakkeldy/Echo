import Foundation
import AVFoundation
import UIKit
import os.log

// MARK: - BookmarkStore

/// Manages bookmark CRUD, voice memo playback, and bookmark-related queries.
/// Owns no persistence directly — callers supply save/load closures so the
/// store stays testable and storage-agnostic.
@MainActor @Observable
final class BookmarkStore: BookmarkStoreProtocol {

    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "BookmarkStore")

    /// All bookmarks for the currently loaded book.
    var bookmarks: [Bookmark] = []

    /// Whether a voice memo is currently playing in overlay mode.
    private(set) var isPlayingVoiceMemo: Bool = false
    /// 0...1 progress of the currently playing voice memo.
    private(set) var voiceMemoProgress: Double = 0.0

    @ObservationIgnored private var voiceMemoEngine: AVAudioEngine?
    @ObservationIgnored private var voiceMemoPlayerNode: AVAudioPlayerNode?
    @ObservationIgnored private var voiceMemoDuration: Double = 0
    @ObservationIgnored private var voiceMemoProgressTimer: Timer?
    @ObservationIgnored private var voiceMemoGainCache: [String: Float] = [:]

    @ObservationIgnored var onSwitchToVoiceMemo: (() -> Void)?
    @ObservationIgnored var onSwitchToMainPlayer: (() -> Void)?
    @ObservationIgnored var onPersist: (([Bookmark]) -> Void)?
    @ObservationIgnored var onDeleteFile: ((URL) -> Void)?
    @ObservationIgnored var onBookmarksChanged: (() -> Void)?
    /// Returns the storage key for the current book. Set by PlayerModel.
    @ObservationIgnored var storageKeyProvider: (() -> String?)?

    // MARK: - Queries

    /// Bookmarks scoped to a specific track ID, sorted by timestamp.
    func trackBookmarks(for trackId: String?) -> [Bookmark] {
        bookmarks
            .filter { $0.trackId == nil || $0.trackId == trackId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Returns the active bookmark with an attached image at or before the
    /// given playback time.
    static func activeArtworkBookmark(from bookmarks: [Bookmark], at currentTime: TimeInterval, trackId: String?) -> Bookmark? {
        bookmarks
            .filter { bookmark in
                guard bookmark.isEnabled,
                      bookmark.bookmarkImageFileName?.isEmpty == false,
                      bookmark.timestamp.isFinite,
                      bookmark.timestamp <= currentTime
                else { return false }

                if let bookmarkTrackId = bookmark.trackId, let trackId {
                    return bookmarkTrackId == trackId
                }
                return bookmark.trackId == nil || trackId == nil
            }
            .max { $0.timestamp < $1.timestamp }
    }

    // MARK: - CRUD

    @discardableResult
    func addBookmark(at time: TimeInterval, trackId: String?, folderKey: String?) -> Bookmark {
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        let bm = Bookmark(
            title: String(localized: "Bookmark \(scopedCount + 1)"),
            folderKey: folderKey,
            trackId: trackId,
            timestamp: time
        )
        bookmarks.append(bm)
        bookmarks.sort { $0.timestamp < $1.timestamp }
        onPersist?(bookmarks)
        postBookmarksDidChange()
        return bm
    }

    func bookmarkDraft(at time: TimeInterval, trackId: String?, folderKey: String?) -> BookmarkDraft {
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        return BookmarkDraft(
            title: String(localized: "Bookmark \(scopedCount + 1)"),
            folderKey: folderKey,
            trackId: trackId,
            timestamp: time
        )
    }

    @discardableResult
    func appendBookmark(
        from draft: BookmarkDraft,
        title: String,
        timestamp: TimeInterval,
        note: String?,
        voiceMemoFileName: String?,
        bookmarkImageFileName: String? = nil
    ) -> Bookmark {
        let bm = Bookmark(
            id: draft.id,
            title: title,
            folderKey: draft.folderKey,
            trackId: draft.trackId,
            timestamp: timestamp,
            note: note,
            voiceMemoFileName: voiceMemoFileName,
            bookmarkImageFileName: bookmarkImageFileName
        )
        bookmarks.append(bm)
        bookmarks.sort { $0.timestamp < $1.timestamp }
        onPersist?(bookmarks)
        onBookmarksChanged?()
        postBookmarksDidChange()
        return bm
    }

    func updateBookmark(
        id: UUID,
        title: String,
        timestamp: TimeInterval,
        note: String?,
        voiceMemoFileName: String?,
        bookmarkImageFileName: String? = nil
    ) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].title = title
        bookmarks[idx].timestamp = timestamp
        bookmarks[idx].note = note
        bookmarks[idx].voiceMemoFileName = voiceMemoFileName
        bookmarks[idx].bookmarkImageFileName = bookmarkImageFileName
        bookmarks.sort { $0.timestamp < $1.timestamp }
        onPersist?(bookmarks)
        onBookmarksChanged?()
        postBookmarksDidChange()
    }

    func toggleBookmarkEnabled(id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].isEnabled.toggle()
        onPersist?(bookmarks)
        onBookmarksChanged?()
        postBookmarksDidChange()
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        var moving: [Bookmark] = []
        for i in source.sorted(by: >) {
            moving.append(bookmarks.remove(at: i))
        }
        let insertIndex = min(destination, bookmarks.count)
        bookmarks.insert(contentsOf: moving.reversed(), at: insertIndex)
        onPersist?(bookmarks)
        onBookmarksChanged?()
        postBookmarksDidChange()
    }

    func deleteBookmark(id: UUID, folderURL: URL? = nil) {
        if let idx = bookmarks.firstIndex(where: { $0.id == id }), let url = folderURL {
            let bm = bookmarks[idx]
            if let memoURL = bm.voiceMemoURL(in: url) {
                onDeleteFile?(memoURL)
            }
            if let imageURL = bm.bookmarkImageURL(in: url) {
                onDeleteFile?(imageURL)
            }
        }
        bookmarks.removeAll { $0.id == id }
        onPersist?(bookmarks)
        onBookmarksChanged?()
        postBookmarksDidChange()
    }

    // MARK: - Voice Memo Playback

    private func cachedVoiceMemoGain(for url: URL) -> Float {
        let key = url.absoluteString
        if let cached = voiceMemoGainCache[key] { return cached }
        let gain = voiceMemoGain(for: url)
        voiceMemoGainCache[key] = gain
        return gain
    }

    func checkVoiceMemoTrigger(
        at currentSeconds: Double,
        previousSeconds: Double?,
        isPlaying: Bool,
        isManualSeeking: Bool,
        loopMode: LoopMode,
        playBookmarksInline: Bool,
        trackId: String?,
        folderURL: URL?,
        lastTriggeredBookmarkID: inout UUID?,
        lastTriggeredAtPlayerSecond: inout Double
    ) -> URL? {
        guard !isPlayingVoiceMemo, isPlaying, !isManualSeeking else { return nil }
        guard loopMode != .bookmark else { return nil }
        guard currentSeconds.isFinite else { return nil }
        guard playBookmarksInline else { return nil }

        let toleranceBefore: Double = 0.1
        let toleranceAfter: Double = 0.75
        let candidates = bookmarks.filter { bm in
            guard bm.isEnabled else { return false }
            guard bm.voiceMemoFileName != nil else { return false }
            if let bt = bm.trackId, let ct = trackId, bt != ct { return false }

            if let previousSeconds, previousSeconds.isFinite {
                let lowerBound = min(previousSeconds, currentSeconds) - toleranceBefore
                let upperBound = max(previousSeconds, currentSeconds) + toleranceBefore
                if bm.timestamp >= lowerBound && bm.timestamp <= upperBound {
                    return true
                }
            }

            let delta = currentSeconds - bm.timestamp
            return delta >= -toleranceBefore && delta <= toleranceAfter
        }

        guard let bm = candidates.max(by: { $0.timestamp < $1.timestamp }) else { return nil }

        if lastTriggeredBookmarkID == bm.id,
           abs(currentSeconds - lastTriggeredAtPlayerSecond) < 5 {
            return nil
        }
        guard let memoURL = bm.voiceMemoURL(in: folderURL),
              FileManager.default.fileExists(atPath: memoURL.path) else { return nil }

        lastTriggeredBookmarkID = bm.id
        lastTriggeredAtPlayerSecond = currentSeconds
        return memoURL
    }

    func startVoiceMemoPlayback(url: URL) {
        onSwitchToVoiceMemo?()
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            engine.mainMixerNode.outputVolume = cachedVoiceMemoGain(for: url)

            try engine.start()

            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            voiceMemoEngine = engine
            voiceMemoPlayerNode = playerNode
            voiceMemoDuration = duration
            isPlayingVoiceMemo = true
            voiceMemoProgress = 0.0

            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                Task { @MainActor in self?.voiceMemoDidFinish() }
            }
            playerNode.play()

            voiceMemoProgressTimer?.invalidate()
            voiceMemoProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          let node = self.voiceMemoPlayerNode,
                          node.isPlaying,
                          let lastTime = node.lastRenderTime,
                          let playerTime = node.playerTime(forNodeTime: lastTime)
                    else { return }
                    let current = Double(playerTime.sampleTime) / playerTime.sampleRate
                    self.voiceMemoProgress = min(1.0, max(0.0, current / self.voiceMemoDuration))
                }
            }
        } catch {
            logger.error("Voice memo playback error: \(error.localizedDescription)")
            onSwitchToMainPlayer?()
        }
    }

    func stopVoiceMemo() {
        voiceMemoPlayerNode?.stop()
        voiceMemoEngine?.stop()
        voiceMemoEngine?.reset()
        voiceMemoProgressTimer?.invalidate()
        voiceMemoProgressTimer = nil
        voiceMemoProgress = 0.0
        voiceMemoPlayerNode = nil
        voiceMemoEngine = nil
        isPlayingVoiceMemo = false
    }

    private func voiceMemoDidFinish() {
        stopVoiceMemo()
        onSwitchToMainPlayer?()
    }

    // MARK: - SQL Persistence

    /// Load bookmarks from SQL for the given audiobook ID.
    func loadFromSQL(database: DatabaseService, audiobookID: String) {
        let dao = BookmarkDAO(db: database.writer)
        do {
            let records = try dao.bookmarks(for: audiobookID)
            self.bookmarks = records.map { $0.toModel() }
        } catch {
            logger.error("Failed to load bookmarks from SQL: \(error.localizedDescription)")
        }
    }

    /// Persist all bookmarks through SQL, keyed by the current storage key.
    func configureSQLPersistence(database: DatabaseService) {
        onPersist = { [weak self] bookmarks in
            guard let self, let key = self.storageKeyProvider?() else { return }
            let dao = BookmarkDAO(db: database.writer)
            do {
                try dao.deleteAll(for: key)
                for bm in bookmarks {
                    try dao.insert(BookmarkRecord(from: bm))
                }
            } catch {
                self.logger.error("Failed to persist bookmarks to SQL: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Notification

    private func postBookmarksDidChange() {
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }
}

// MARK: - Bookmark Change Notification

extension Notification.Name {
    /// Posted when the bookmark store persists changes (add, update, delete).
    /// The Timeline feed observes this to refresh inline bookmark items.
    static let bookmarksDidChange = Notification.Name("BookmarksDidChange")
}
