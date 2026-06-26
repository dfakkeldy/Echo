#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import os.log

// MARK: - Bookmarks API

enum PlayerDocumentImportError: LocalizedError {
    case noActiveBook
    case databaseUnavailable

    nonisolated var errorDescription: String? {
        switch self {
        case .noActiveBook:
            return "Open a book before importing a document."
        case .databaseUnavailable:
            return "Document import is unavailable for the current book."
        }
    }
}

extension PlayerModel {

    /// The persistence key for the currently loaded book, derived from the folder
    /// URL or the current track ID. Used to scope bookmark and progress storage.
    var bookmarksStorageKey: String? {
        if let f = folderURL?.absoluteString { return f }
        if state.tracks.indices.contains(currentIndex) { return state.tracks[currentIndex].id }
        return nil
    }

    /// Loads bookmarks from persistent storage for the currently loaded book.
    /// Falls back to an empty list if no storage key is available.
    func loadBookmarksForCurrentBook() {
        guard let key = bookmarksStorageKey else {
            bookmarkStore.bookmarks = []
            artworkCoordinator.updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
            return
        }
        bookmarkStore.bookmarks = persistence.loadBookmarks(for: key, folderURL: folderURL).sorted {
            $0.timestamp < $1.timestamp
        }
        artworkCoordinator.updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
    }

    /// Bookmarks scoped to the currently playing track, sorted by timestamp.
    var currentTrackBookmarks: [Bookmark] {
        let trackId =
            state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        return bookmarkStore.trackBookmarks(for: trackId)
    }

    /// Bookmark looping needs two enabled, finite bookmarks to define a segment.
    var canBookmarkLoop: Bool {
        currentTrackBookmarks.filter { $0.isEnabled && $0.timestamp.isFinite }.count >= 2
    }

    /// Creates a new bookmark at the current playback position with an
    /// auto-numbered title. Persists the bookmark list immediately.
    /// - Returns: The newly created bookmark, or `nil` if playback is unavailable.
    @discardableResult
    func addBookmarkAtCurrentTime() -> Bookmark? {
        guard audioEngine.isItemLoaded else { return nil }
        let t = audioEngine.currentTime
        guard t.isFinite else { return nil }
        let trackId =
            state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        let bookmark = bookmarkStore.addBookmark(
            at: t, trackId: trackId, folderKey: folderURL?.absoluteString)
        logRealTimeEvent(
            type: .bookmarkCreated, title: bookmark.title, timestamp: t,
            sourceItemID: bookmark.id.uuidString, sourceItemType: "bookmark")
        captureLocationForBookmark(bookmark.id)
        return bookmark
    }

    /// Creates a draft bookmark at the current playback position without
    /// persisting it. Useful for presenting a pre-filled editor before saving.
    /// - Returns: A draft bookmark, or `nil` if playback is unavailable.
    func bookmarkDraftAtCurrentTime() -> BookmarkDraft? {
        guard audioEngine.isItemLoaded else { return nil }
        let t = audioEngine.currentTime
        guard t.isFinite else { return nil }
        let trackId =
            state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        let draft = bookmarkStore.bookmarkDraft(
            at: t, trackId: trackId, folderKey: folderURL?.absoluteString)
        if let pdfState = currentPDFViewState {
            return BookmarkDraft(
                id: draft.id, title: draft.title, folderKey: draft.folderKey,
                trackId: draft.trackId, timestamp: draft.timestamp, pdfViewState: pdfState)
        }
        return draft
    }

    /// Appends a bookmark created from a draft, persisting the updated list.
    @discardableResult
    func appendBookmark(
        from draft: BookmarkDraft,
        title: String,
        timestamp: TimeInterval,
        note: String?,
        voiceMemoFileName: String?,
        bookmarkImageFileName: String? = nil
    ) -> Bookmark {
        let bookmark = bookmarkStore.appendBookmark(
            from: draft, title: title, timestamp: timestamp, note: note,
            voiceMemoFileName: voiceMemoFileName, bookmarkImageFileName: bookmarkImageFileName
        )
        logRealTimeEvent(
            type: .bookmarkCreated, title: title, timestamp: timestamp,
            sourceItemID: bookmark.id.uuidString, sourceItemType: "bookmark")
        captureLocationForBookmark(bookmark.id)
        return bookmark
    }

    /// Fire-and-forget location capture for a bookmark that was just created.
    /// Never blocks the user action — location arrives asynchronously and updates the bookmark in-place.
    private func captureLocationForBookmark(_ bookmarkID: UUID) {
        guard databaseService != nil, settingsManager?.locationCaptureEnabled ?? false else {
            return
        }
        let capture = locationCapture
        let store = bookmarkStore
        Task {
            guard let place = await capture.capture() else { return }
            await MainActor.run {
                store.updateLocation(
                    id: bookmarkID,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    placeName: place.placeName
                )
            }
        }
    }

    /// Updates an existing bookmark's metadata and re-persists the list.
    func updateBookmark(
        id: UUID,
        title: String,
        timestamp: TimeInterval,
        note: String?,
        voiceMemoFileName: String?,
        bookmarkImageFileName: String? = nil
    ) {
        artworkCoordinator.invalidateCache()
        bookmarkStore.updateBookmark(
            id: id, title: title, timestamp: timestamp, note: note,
            voiceMemoFileName: voiceMemoFileName, bookmarkImageFileName: bookmarkImageFileName
        )
    }

    @discardableResult
    func importEPUBDocument(from sourceURL: URL) async throws -> EPUBImportCoordinator.ImportResult {
        guard let folderURL else { throw PlayerDocumentImportError.noActiveBook }
        guard let db = databaseService else { throw PlayerDocumentImportError.databaseUnavailable }

        let result = try await EPUBImportCoordinator.importEPUB(
            from: sourceURL,
            to: folderURL,
            databaseService: db,
            chapters: state.chapters,
            duration: state.durationSeconds
        )

        // The import wiped and re-created epub_block rows (cascade-deleting
        // their anchors); timeline_item still references the dead block IDs.
        // Rebuild it so the reader and timeline feed reflect the new import.
        await reingestTimelineFromEPUB()
        playbackController.state.documentIngestionTrigger += 1

        return result
    }

    func importEPUB(from sourceURL: URL) {
        let logger = Logger(category: "PlayerDocumentImport")
        Task {
            do {
                _ = try await self.importEPUBDocument(from: sourceURL)
            } catch {
                logger.error("EPUB import failed: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the selected PDF file into the current audiobook folder.
    @discardableResult
    func importPDFDocument(from sourceURL: URL) async throws -> PDFImportCoordinator.ImportResult {
        guard let folderURL else { throw PlayerDocumentImportError.noActiveBook }
        guard let db = databaseService else { throw PlayerDocumentImportError.databaseUnavailable }

        let result = try await PDFImportCoordinator.importPDF(
            from: sourceURL,
            to: folderURL,
            databaseService: db,
            chapters: state.chapters,
            duration: state.durationSeconds
        )
        playbackController.state.documentIngestionTrigger += 1
        NotificationCenter.default.post(
            name: .timelineItemsIngested,
            object: nil,
            userInfo: ["audiobookID": folderURL.absoluteString]
        )

        return result
    }

    func importPDF(from sourceURL: URL) {
        let logger = Logger(category: "PlayerDocumentImport")
        Task {
            do {
                _ = try await self.importPDFDocument(from: sourceURL)
            } catch {
                logger.error("PDF import failed: \(error.localizedDescription)")
            }
        }
    }

    func addWatchBookmark(from payload: [String: Any]) {
        guard let storageKey = payload["bookmarkStorageKey"] as? String else { return }

        let folderKey = payload["folderKey"] as? String
        let trackId = payload["trackId"] as? String
        let note = (payload["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceMemoFileName = payload["voiceMemoFileName"] as? String
        let incomingTimestamp = payload["timestamp"] as? Double
        let timestamp = max(0, incomingTimestamp?.isFinite == true ? incomingTimestamp ?? 0 : 0)

        let isCurrentBook = storageKey == bookmarksStorageKey
        // Only the currently-loaded book has live security scope, so sidecar
        // I/O is restricted to that case; other books fall back to UserDefaults.
        let targetFolderURL: URL? = isCurrentBook ? folderURL : nil
        var targetBookmarks =
            isCurrentBook
            ? bookmarkStore.bookmarks
            : persistence.loadBookmarks(for: storageKey, folderURL: targetFolderURL)
        let scopedCount = targetBookmarks.filter { $0.trackId == nil || $0.trackId == trackId }
            .count

        let bookmark = Bookmark(
            title: String(localized: "Bookmark \(scopedCount + 1)"),
            folderKey: folderKey,
            trackId: trackId,
            timestamp: timestamp,
            note: note?.isEmpty == true ? nil : note,
            voiceMemoFileName: voiceMemoFileName
        )

        targetBookmarks.append(bookmark)
        targetBookmarks.sort { $0.timestamp < $1.timestamp }
        persistence.saveBookmarks(targetBookmarks, for: storageKey, folderURL: targetFolderURL)

        if isCurrentBook {
            bookmarkStore.bookmarks = targetBookmarks

        }
    }

    /// Toggles the enabled state of a bookmark. Disabled bookmarks are skipped
    /// during bookmark-loop navigation and voice-memo triggering.
    func toggleBookmarkEnabled(id: UUID) {
        bookmarkStore.toggleBookmarkEnabled(id: id)
    }

    /// Reorders bookmarks within the list and persists the new ordering.
    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarkStore.moveBookmarks(from: source, to: destination)
    }

    /// Deletes a bookmark and its associated voice memo / image files (if any).
    /// Automatically disables bookmark loop mode if no bookmarks remain.
    func deleteBookmark(id: UUID) {
        bookmarkStore.deleteBookmark(id: id, folderURL: folderURL)
    }

    /// Seeks to an aggregated chapter position, switching books if necessary.
    /// Used by CarPlay's browse template for multi-M4B chapter navigation.
    func seekToAggregatedChapterPosition(bookIndex: Int, startSeconds: TimeInterval) {
        guard state.m4bBooks.indices.contains(bookIndex) else { return }
        if bookIndex != state.currentIndex {
            state.pendingAggregatedChapter = state.aggregatedChapters.first {
                $0.bookIndex == bookIndex && abs($0.startSeconds - startSeconds) < 1
            }
            skipToTrack(bookIndex)
        } else {
            let bookOffset = state.m4bBooks[bookIndex].cumulativeStartOffset
            let intraBookTime = max(0, startSeconds - bookOffset) + 0.05
            seek(toSeconds: intraBookTime)
        }
    }

    /// Switches playback to a different track index, used by the multi-M4B
    /// chapter list to jump to a specific book.
    func skipToTrack(_ index: Int) {
        guard state.tracks.indices.contains(index), index != state.currentIndex else { return }
        stop()
        playerLoadingCoordinator.prepareToPlay(index: index, autoplay: true)
    }

    /// Jumps playback to a bookmark's timestamp, suppressing the voice-memo
    /// overlay trigger to avoid unwanted playback interruption.
    func jumpToBookmark(_ bm: Bookmark) {
        // Suppress retrigger when the user manually navigates to a bookmark.
        lastTriggeredBookmarkID = bm.id
        lastTriggeredAtPlayerSecond = bm.timestamp
        if let pdfState = bm.pdfViewState {
            pendingPDFViewStateRestore = pdfState
        }
        seek(toSeconds: bm.timestamp)
    }
}

#endif
