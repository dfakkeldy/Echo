import Foundation
import AVFoundation
import os.log

// MARK: - PlayerLoadingCoordinator

/// Orchestrates folder and track loading: playlist enumeration, multi-M4B
/// aggregation, non-M4B multi-file timeline ingestion, last-track restore,
/// manifest migration, EPUB auto-import kickoff, and per-track preparation.
/// Extracted from PlayerModel to keep it focused on playback orchestration.
final class PlayerLoadingCoordinator {

    // MARK: - Dependencies (set by PlayerModel)

    @ObservationIgnored var state: PlaybackState?
    @ObservationIgnored var audioEngine: AudioEngine?
    @ObservationIgnored var playbackController: PlaybackController?
    @ObservationIgnored var playlistManager: PlaylistManager?
    @ObservationIgnored var persistence: Persistence?
    @ObservationIgnored var timelinePersistence: PlayerTimelinePersistenceService?
    @ObservationIgnored var bookSettingsOverrideStore: BookSettingsOverrideStore?
    @ObservationIgnored var securityScope: SecurityScopeManager?
    @ObservationIgnored var artworkCoordinator: BookmarkArtworkCoordinator?
    @ObservationIgnored var flashcardTriggerController: InlineFlashcardTriggerController?
    @ObservationIgnored var bookmarkStore: BookmarkStore?
    @ObservationIgnored var progressPresenter: PlaybackProgressPresenter?
    @ObservationIgnored var chapterLoadingCoordinator: ChapterLoadingCoordinator?
    @ObservationIgnored var watchSyncManager: WatchSyncManager?
    @ObservationIgnored var transcriptService: TranscriptService?
    @ObservationIgnored var nowPlayingController: NowPlayingController?
    @ObservationIgnored var deepLinkHandler: DeepLinkHandler?

    private var pendingArtworkTask: Task<Void, Never>?

    /// Value providers for properties owned by PlayerModel.
    @ObservationIgnored var databaseServiceProvider: (() -> DatabaseService?)?
    @ObservationIgnored var resolvedVolumeBoostEnabledProvider: (() -> Bool)?
    @ObservationIgnored var defaultPlaybackSpeedProvider: (() -> Float)?

    /// Callbacks for PlayerModel-specific behavior.
    @ObservationIgnored var onConfigureRemoteCommands: (() -> Void)?
    @ObservationIgnored var onPersistSelection: ((URL) -> Void)?
    /// Resets the player-level bookmark-check timestamp, used to avoid
    /// stale state bleeding across track boundaries.
    @ObservationIgnored var onResetBookmarkCheckSecond: (() -> Void)?
    @ObservationIgnored var onConfigureContinuousAlignment: (() -> Void)?

    // MARK: - Folder loading

    /// Loads a folder or single audio file as the active playlist. If the URL is a
    /// directory, all supported audio files are enumerated and sorted; if a single
    /// file, it becomes the sole track. Stops any current playback first.
    /// - Parameters:
    ///   - url: The folder or file URL to load.
    ///   - autoplay: Whether to automatically begin playback after loading. Defaults to `true`.
    func loadFolder(_ url: URL, autoplay: Bool = true) {
        guard let state, let playbackController, let playlistManager, let persistence,
              let timelinePersistence, let bookSettingsOverrideStore, let bookmarkStore else { return }

        // ── Save the *current* book's progress before it gets overwritten ──
        // stop() zeroes audioEngine.currentTime, and state.folderURL is about to
        // change to the new book's key.  Capture both now so the old book's
        // last-known-good position is persisted under the correct folder key.
        if let oldFolderKey = state.folderURL?.absoluteString,
           state.tracks.indices.contains(state.currentIndex),
           let audioEngine {
            let oldTrackId = state.tracks[state.currentIndex].id
            let oldTime = audioEngine.currentTime
            persistence.saveBookProgress(for: oldFolderKey, trackId: oldTrackId, time: oldTime, folderURL: state.folderURL)
        }

        playbackController.stop()

        // Start security-scoped access for the entire folder loading flow.
        // Must stay alive through async EPUB import, which runs after this method returns.
        // Uses the document picker's exact URL — security scope is tied to this URL.
        securityScope?.startSelection(url: url)

        let isDir = loadTracksAndDetectDirectory(url: url, state: state, playlistManager: playlistManager)

        // Normalize folderURL to always be a directory. When the user opens a
        // single file (e.g. an M4B), use its parent directory as the canonical
        // key for persistence, timeline items, EPUB blocks, and CloudKit sync.
        // This ensures opening the folder and opening any file within it
        // produce the same audiobookID — so EPUBs load consistently and
        // playback position is shared across both entry points.
        if isDir {
            state.folderURL = url
        } else {
            let parentDir = url.deletingLastPathComponent()
            state.folderURL = parentDir
            // Start security-scoped access on the parent directory so
            // EPUB auto-import can enumerate sibling files.
            _ = parentDir.startAccessingSecurityScopedResource()
        }

        // Load per-book settings overrides
        bookSettingsOverrideStore.loadOverrides(for: url.absoluteString)
        playbackController.setVolumeBoost(enabled: resolvedVolumeBoostEnabledProvider?() ?? false)

        // Persist to SQL after tracks are loaded so the DB has accurate track data.
        timelinePersistence.persistAudiobookToSQL(folderURL: url, tracks: state.tracks, duration: state.durationSeconds)

        // Ingest chapter metadata (M4B aggregation or multi-track chapter parsing).
        ingestChapterMetadata(folderURL: url, state: state, timelinePersistence: timelinePersistence)

        // Restore last track position or start from the beginning.
        restoreTrackPosition(folderURL: url, state: state, persistence: persistence, autoplay: autoplay)

        // Migrate per-folder UserDefaults state into .echoplaylist.json if needed.
        migrateManifestIfNeeded(isDir: isDir, folderURL: url, state: state, persistence: persistence, bookmarkStore: bookmarkStore)

        onPersistSelection?(url)

        // Post-load hooks: SQL bookmarks, EPUB auto-import.
        // Use the normalized folderURL (always a directory — see above) so
        // EPUB blocks are keyed consistently regardless of entry point.
        guard let db = databaseServiceProvider?() else { return }
        bookmarkStore.configureSQLPersistence(database: db)
        onConfigureContinuousAlignment?()
    }

    // MARK: - loadFolder helpers

    /// Loads tracks from a folder or single file, returning whether the URL was a directory.
    private func loadTracksAndDetectDirectory(url: URL, state: PlaybackState, playlistManager: PlaylistManager) -> Bool {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            state.tracks = playlistManager.loadTracks(from: url)
        } else {
            state.tracks = [Track(url: url, title: url.deletingPathExtension().lastPathComponent)]
        }
        return isDir
    }

    /// Ingests chapter metadata: multi-M4B aggregation or per-track chapter parsing.
    private func ingestChapterMetadata(folderURL: URL, state: PlaybackState, timelinePersistence: PlayerTimelinePersistenceService) {
        let m4bTrackCount = state.tracks.filter { $0.url.pathExtension.lowercased() == "m4b" }.count
        if m4bTrackCount >= 2 {
            ingestMultiM4BChapters(folderURL: folderURL, state: state, timelinePersistence: timelinePersistence)
        } else if state.tracks.count > 1 {
            ingestMultiTrackChapters(folderURL: folderURL, tracks: state.tracks, state: state, timelinePersistence: timelinePersistence)
        }
    }

    private func ingestMultiM4BChapters(folderURL: URL, state: PlaybackState, timelinePersistence: PlayerTimelinePersistenceService) {
        Task {
            guard let parsed = await M4BParser.parseFolder(folderURL) else { return }
            state.m4bBooks = parsed.books
            state.aggregatedChapters = parsed.aggregatedChapters
            state.totalBookDuration = parsed.totalDuration

            let chapters = parsed.aggregatedChapters.map { agg in
                Chapter(index: agg.chapterIndex, title: agg.chapterTitle, startSeconds: agg.startSeconds, endSeconds: agg.endSeconds, isEnabled: true)
            }
            let audioURL = parsed.books.first?.url ?? folderURL
            await timelinePersistence.ingestTimelineItems(
                audiobookID: folderURL.absoluteString, audioURL: audioURL, chapters: chapters,
                transcription: state.transcription, enhancedTranscription: state.enhancedTranscription, folderURL: folderURL
            )
        }
    }

    private func ingestMultiTrackChapters(folderURL: URL, tracks: [Track], state: PlaybackState, timelinePersistence: PlayerTimelinePersistenceService) {
        Task {
            var allChapters: [Chapter] = []
            for track in tracks {
                let asset = AVURLAsset(url: track.url)
                let parsed = await ChapterService.parseChapters(from: asset)
                if parsed.count >= 2 {
                    for ch in parsed {
                        allChapters.append(Chapter(index: allChapters.count, title: ch.title, startSeconds: ch.startSeconds, endSeconds: ch.endSeconds, isEnabled: ch.isEnabled))
                    }
                } else {
                    let ext = track.url.pathExtension.lowercased()
                    let duration: TimeInterval = (ext == "m4b" || ext == "m4a") ? ((try? await asset.load(.duration))?.seconds ?? 0) : 0
                    allChapters.append(Chapter(index: allChapters.count, title: track.title, startSeconds: 0, endSeconds: duration.isFinite ? duration : 0, isEnabled: true))
                }
            }
            guard !allChapters.isEmpty else { return }
            await timelinePersistence.ingestTimelineItems(
                audiobookID: folderURL.absoluteString, audioURL: tracks[0].url, chapters: allChapters,
                transcription: state.transcription, enhancedTranscription: state.enhancedTranscription, folderURL: folderURL
            )
        }
    }

    /// Restores the last-played track index, or defaults to 0.
    private func restoreTrackPosition(folderURL: URL, state: PlaybackState, persistence: Persistence, autoplay: Bool) {
        if let folderKey = state.folderURL?.absoluteString {
            state.pauseTimestamp = persistence.getPauseTimestamp(for: folderKey)
            if let savedTrackId = persistence.getLastTrack(for: folderKey),
               let idx = state.tracks.firstIndex(where: { $0.id == savedTrackId }) {
                state.currentIndex = idx
            } else {
                state.currentIndex = 0
            }
        } else {
            state.currentIndex = 0
        }

        if state.tracks.indices.contains(state.currentIndex) {
            state.currentTitle = state.tracks[state.currentIndex].title
            prepareToPlay(index: state.currentIndex, autoplay: autoplay)
            applyPendingDeepLinkSeekIfPossible()
        } else {
            state.currentTitle = String(localized: "No .mp3/.m4a/.m4b files found")
            progressPresenter?.updateNowPlayingInfo(isPaused: true)
        }
    }

    /// Migrates per-folder UserDefaults state into .echoplaylist.json if no manifest exists yet.
    private func migrateManifestIfNeeded(isDir: Bool, folderURL: URL, state: PlaybackState, persistence: Persistence, bookmarkStore: BookmarkStore) {
        guard isDir, !state.tracks.isEmpty else { return }
        let manifestURL = folderURL.appendingPathComponent(PlaylistManifestService.fileName)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let manifest = PlaylistManifestService.migrate(
            from: persistence, folderURL: folderURL, tracks: state.tracks,
            bookmarks: bookmarkStore.bookmarks, defaultSpeed: defaultPlaybackSpeedProvider?() ?? 1.25
        )
        PlaylistManifestService.write(manifest, to: folderURL)
    }

    // MARK: - Track preparation

    func prepareToPlay(index: Int, autoplay: Bool) {
        guard let state, let audioEngine, let playbackController, let persistence,
              let artworkCoordinator, let flashcardTriggerController,
              let progressPresenter, let chapterLoadingCoordinator,
              let watchSyncManager, let transcriptService else { return }
        guard state.tracks.indices.contains(index) else { return }

        saveProgressBeforeTrackChange(state: state, persistence: persistence, audioEngine: audioEngine)
        configureTrackState(state: state, index: index, persistence: persistence, playbackController: playbackController, audioEngine: audioEngine)
        resetPerTrackState(state: state, flashcardTriggerController: flashcardTriggerController, artworkCoordinator: artworkCoordinator, transcriptService: transcriptService)
        setupAudioForTrack(state: state, index: index, audioEngine: audioEngine, playbackController: playbackController)

        // Prime Now Playing metadata even before play (helps show stable controls)
        progressPresenter.updateNowPlayingInfo(isPaused: true)
        progressPresenter.updateProgress()
        watchSyncManager.syncToWatch()

        // Load chapters, thumbnail, and handle autoplay/seek.
        performPostLoadTasks(state: state, audioEngine: audioEngine, playbackController: playbackController,
                             chapterLoadingCoordinator: chapterLoadingCoordinator, artworkCoordinator: artworkCoordinator, autoplay: autoplay)
    }

    // MARK: - prepareToPlay helpers

    private func saveProgressBeforeTrackChange(state: PlaybackState, persistence: Persistence, audioEngine: AudioEngine) {
        // Only save progress when there's an actual item loaded with a meaningful
        // playback position. After stop() — which is called during loadFolder before
        // prepareToPlay — isItemLoaded is false and currentTime is 0. Saving 0 would
        // corrupt the per-book progress that was just written by the old-book save
        // in loadFolder, causing the position-restore seek in onDurationLoaded to
        // be skipped (its guard requires progress.time > 0).
        guard let folder = state.folderURL?.absoluteString,
              state.tracks.indices.contains(state.currentIndex),
              audioEngine.isItemLoaded else { return }
        let time = audioEngine.currentTime
        guard time > 0 else { return }
        persistence.saveBookProgress(for: folder, trackId: state.tracks[state.currentIndex].id, time: time, folderURL: state.folderURL)
    }

    private func configureTrackState(state: PlaybackState, index: Int, persistence: Persistence, playbackController: PlaybackController, audioEngine: AudioEngine) {
        state.currentIndex = index
        state.currentTitle = state.tracks[index].title
        state.currentSubtitle = ""

        if let folderURL = state.folderURL {
            persistence.saveLastTrack(for: folderURL.absoluteString, trackId: state.tracks[index].id, folderURL: folderURL)
        }

        // Load per-book speed and loop mode.
        if let key = state.folderURL?.absoluteString {
            playbackController.speed = persistence.getSpeed(for: key, folderURL: state.folderURL) ?? defaultPlaybackSpeedProvider?() ?? 1.25
            if let raw = persistence.getLoopMode(for: key, folderURL: state.folderURL), let mode = LoopMode(rawValue: raw) {
                playbackController.loopMode = mode
            } else {
                playbackController.loopMode = .off
            }
        } else {
            playbackController.speed = defaultPlaybackSpeedProvider?() ?? 1.25
            playbackController.loopMode = .off
        }
        audioEngine.setSpeed(playbackController.speed)

        // Multi-M4B: load the correct book's chapter list and duration.
        if state.isMultiM4B, state.m4bBooks.indices.contains(index) {
            let book = state.m4bBooks[index]
            state.chapters = book.chapters
            state.durationSeconds = book.duration
            state.totalBookDuration = state.m4bBooks.reduce(0) { $0 + $1.duration }
        }
    }

    private func resetPerTrackState(state: PlaybackState, flashcardTriggerController: InlineFlashcardTriggerController, artworkCoordinator: BookmarkArtworkCoordinator, transcriptService: TranscriptService) {
        state.thumbnailImage = nil
        state.chapters = []
        state.currentChapterIndex = nil
        state.isSeekingForChapterBoundary = false
        state.isManualSeeking = false
        artworkCoordinator.invalidateCache()
        onResetBookmarkCheckSecond?()
        flashcardTriggerController.resetForNewTrack()

        // Load transcript for the new track
        transcriptService.loadTranscript(for: state.tracks[state.currentIndex].url)
        if let audiobookID = state.folderURL?.absoluteString {
            timelinePersistence?.persistTranscriptToSQL(audiobookID: audiobookID, transcription: state.transcription)
        }
    }

    private func setupAudioForTrack(state: PlaybackState, index: Int, audioEngine: AudioEngine, playbackController: PlaybackController) {
        if let folderURL = state.folderURL {
            securityScope?.startSelection(url: folderURL)
        }
        securityScope?.stopFile()
        securityScope?.startFile(url: state.tracks[index].url)

        let trackURL = state.tracks[index].url
        pendingArtworkTask?.cancel()
        pendingArtworkTask = Task { await ArtworkCache.ensureItemIsAvailable(url: trackURL) }

        audioEngine.configureAudioSession()
        audioEngine.replaceCurrentItem(with: trackURL)
        playbackController.applySpeedToCurrentItem()
        onConfigureRemoteCommands?()
    }

    private func performPostLoadTasks(state: PlaybackState, audioEngine: AudioEngine, playbackController: PlaybackController,
                                       chapterLoadingCoordinator: ChapterLoadingCoordinator, artworkCoordinator: BookmarkArtworkCoordinator, autoplay: Bool) {
        let trackURL = state.tracks[state.currentIndex].url
        Task { @MainActor [weak self] in
            guard let self else { return }
            await chapterLoadingCoordinator.loadChaptersForCurrentItem()
            await chapterLoadingCoordinator.loadDurationForNowPlaying()
            await artworkCoordinator.generateThumbnail(for: trackURL)

            if let pending = state.pendingAggregatedChapter {
                state.pendingAggregatedChapter = nil
                let bookOffset = state.m4bBooks.indices.contains(pending.bookIndex)
                    ? state.m4bBooks[pending.bookIndex].cumulativeStartOffset : 0
                let intraBookTime = max(0, pending.startSeconds - bookOffset) + 0.05
                audioEngine.seek(to: intraBookTime) { [weak self] _ in
                    self?.playbackController?.resumeAfterSeek()
                }
            } else if autoplay {
                playbackController.play()
            }
            
            if let folderURL = state.folderURL, let db = self.databaseServiceProvider?() {
                let currentChapters: [Chapter]
                if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
                    currentChapters = state.aggregatedChapters.map { agg in
                        Chapter(index: agg.chapterIndex, title: agg.chapterTitle, startSeconds: agg.startSeconds, endSeconds: agg.endSeconds, isEnabled: true)
                    }
                } else {
                    currentChapters = state.chapters
                }
                let currentDuration = state.isMultiM4B ? state.totalBookDuration : state.durationSeconds
                let didImport = await EPUBAutoImportScanner.scanAndImportIfNeeded(
                    folderURL: folderURL, databaseService: db, chapters: currentChapters, duration: currentDuration
                )
                if didImport, let timelinePersistence = self.timelinePersistence {
                    // A first-time import lands after the load-time ingestion pass,
                    // so timeline_item has no EPUB-block rows yet. Rebuild it now
                    // that blocks exist, or the reader/feed shows no timestamps
                    // until the next load.
                    await timelinePersistence.ingestTimelineItems(
                        audiobookID: folderURL.absoluteString,
                        audioURL: trackURL,
                        chapters: currentChapters,
                        transcription: state.transcription,
                        enhancedTranscription: state.enhancedTranscription,
                        folderURL: folderURL
                    )
                }
            }
        }
    }

    // MARK: - Private helpers

    private func applyPendingDeepLinkSeekIfPossible() {
        guard var handler = deepLinkHandler, let audioEngine, let playbackController else { return }
        guard let action = handler.applyPendingSeekIfPossible(
            isItemLoaded: audioEngine.isItemLoaded
        ) else { return }
        deepLinkHandler = handler
        if case .seek(let time) = action {
            playbackController.seek(toSeconds: time)
        }
    }
}
