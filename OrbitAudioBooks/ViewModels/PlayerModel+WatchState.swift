import Foundation

// MARK: - Watch State Serialization

extension PlayerModel {

    var currentArtworkSyncKey: String? {
        artworkCoordinator.currentArtworkSyncKey
    }

    /// Thin wrapper that gathers a snapshot of the current state and delegates
    /// dictionary assembly to `WatchStateContextBuilder`.
    func watchStateContext() -> [String: Any] {
        let snapshot = buildWatchStateSnapshot()
        return WatchStateContextBuilder.build(from: snapshot)
    }

    private func buildWatchStateSnapshot() -> WatchStateSnapshot {
        var s = WatchStateSnapshot()

        // Playback state
        s.isPlaying = isPlaying
        s.progressFraction = progressFraction
        s.currentPlaybackTime = currentPlaybackTime
        s.currentIndex = currentIndex
        s.trackCount = tracks.count
        if tracks.indices.contains(currentIndex) {
            s.currentTrackId = tracks[currentIndex].id
        }
        s.durationSeconds = durationSeconds

        // Display title
        s.chapterCount = chapters.count
        s.currentSubtitle = currentSubtitle
        s.currentTitle = currentTitle
        s.currentChapterIndex = currentChapterIndex

        // Storage keys
        s.bookmarkStorageKey = bookmarksStorageKey
        s.folderKey = folderURL?.absoluteString

        // Settings (pre-resolved from SettingsManager)
        let settings = settingsManager
        s.crownAction = settings?.crownAction ?? SettingsManager.Defaults.crownAction
        s.isHapticFeedbackEnabled = settings?.isHapticFeedbackEnabled ?? SettingsManager.Defaults.isHapticFeedbackEnabled
        s.watchQuickBookmarkTimeoutSeconds = settings?.watchQuickBookmarkTimeoutSeconds ?? SettingsManager.Defaults.watchQuickBookmarkTimeoutSeconds
        s.loopModeRawValue = loopMode.rawValue
        s.playbackSpeed = Double(speed)
        s.watchPage1Data = (try? JSONEncoder().encode(settings?.watchPage1 ?? SettingsManager.Defaults.watchPage1)) ?? Data()
        s.watchPage2Data = (try? JSONEncoder().encode(settings?.watchPage2 ?? SettingsManager.Defaults.watchPage2)) ?? Data()
        s.linearBarMode = settings?.linearBarMode ?? SettingsManager.Defaults.linearBarMode
        s.linearBarHidden = settings?.linearBarHidden ?? SettingsManager.Defaults.linearBarHidden
        s.circularRingMode = settings?.circularRingMode ?? SettingsManager.Defaults.circularRingMode
        s.circularRingHidden = settings?.circularRingHidden ?? SettingsManager.Defaults.circularRingHidden
        s.watchArtworkLayout = settings?.watchArtworkLayout ?? SettingsManager.Defaults.watchArtworkLayout
        s.watchBackgroundStyle = settings?.watchBackgroundStyle ?? SettingsManager.Defaults.watchBackgroundStyle

        // Thumbnail availability
        s.hasThumbnail = watchThumbnailData != nil

        // Sleep timer state
        s.sleepTimerMode = sleepTimerMode
        s.sleepTimerRemainingSeconds = sleepTimerRemainingSeconds

        // Word cloud (top 10 words for current chapter)
        s.wordCloud = Array(currentChapterWordCloud.prefix(10))

        // Due flashcards
        if let db = databaseService,
           let cards = try? FlashcardDAO(db: db.writer).allDueCards(),
           !cards.isEmpty {
            s.dueFlashcards = cards.map {
                WatchFlashcard(id: $0.id, frontText: $0.frontText, backText: $0.backText)
            }
        }

        return s
    }
}
