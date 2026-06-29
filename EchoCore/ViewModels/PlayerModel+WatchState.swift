#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OSLog

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
        s.currentPlaybackTime = cumulativePlaybackTime
        s.currentIndex = currentIndex
        s.trackCount = tracks.count
        if tracks.indices.contains(currentIndex) {
            s.currentTrackId = tracks[currentIndex].id
        }
        let bookDuration = state.effectiveBookDuration
        s.durationSeconds = bookDuration > 0 ? bookDuration : durationSeconds

        // Display title
        s.chapterCount = chapters.count
        s.currentSubtitle = currentSubtitle
        s.currentTitle = currentTitle
        s.currentChapterIndex = currentChapterIndex
        if let idx = currentChapterIndex, chapters.indices.contains(idx) {
            let c = chapters[idx]
            s.chapterDuration = c.endSeconds - c.startSeconds
        }

        // Storage keys
        s.bookmarkStorageKey = bookmarksStorageKey
        s.folderKey = folderURL?.absoluteString

        // Settings (pre-resolved from SettingsManager)
        let settings = settingsManager
        s.crownAction = settings?.crownAction ?? SettingsManager.Defaults.crownAction
        s.isHapticFeedbackEnabled = settings?.isHapticFeedbackEnabled ?? SettingsManager.Defaults.isHapticFeedbackEnabled
        s.watchQuickBookmarkTimeoutSeconds = settings?.watchQuickBookmarkTimeoutSeconds ?? SettingsManager.Defaults.watchQuickBookmarkTimeoutSeconds
        s.seekBackwardDuration = settings?.seekBackwardDuration ?? SettingsManager.Defaults.seekBackwardDuration
        s.seekForwardDuration = settings?.seekForwardDuration ?? SettingsManager.Defaults.seekForwardDuration
        s.loopModeRawValue = loopMode.rawValue
        s.playbackSpeed = Double(speed)
        s.watchPage1Data = (try? JSONEncoder().encode(settings?.watchPage1 ?? SettingsManager.Defaults.watchPage1)) ?? Data()
        s.watchPage2Data = (try? JSONEncoder().encode(settings?.watchPage2 ?? SettingsManager.Defaults.watchPage2)) ?? Data()
        s.watchPage3Data = (try? JSONEncoder().encode(settings?.watchPage3 ?? SettingsManager.Defaults.watchPage3)) ?? Data()
        s.watchPage4Data = (try? JSONEncoder().encode(settings?.watchPage4 ?? SettingsManager.Defaults.watchPage4)) ?? Data()
        s.watchPage5Data = (try? JSONEncoder().encode(settings?.watchPage5 ?? SettingsManager.Defaults.watchPage5)) ?? Data()
        s.linearBarMode = settings?.linearBarMode ?? SettingsManager.Defaults.linearBarMode
        s.linearBarHidden = settings?.linearBarHidden ?? SettingsManager.Defaults.linearBarHidden
        s.circularRingMode = settings?.circularRingMode ?? SettingsManager.Defaults.circularRingMode
        s.circularRingHidden = settings?.circularRingHidden ?? SettingsManager.Defaults.circularRingHidden
        s.watchArtworkLayout = settings?.watchArtworkLayout ?? SettingsManager.Defaults.watchArtworkLayout
        s.watchBackgroundStyle = settings?.watchBackgroundStyle ?? SettingsManager.Defaults.watchBackgroundStyle
        s.watchTitleScrollEnabled = settings?.watchTitleScrollEnabled ?? SettingsManager.Defaults.watchTitleScrollEnabled
        s.watchTitleScrollSpeed = settings?.watchTitleScrollSpeed ?? SettingsManager.Defaults.watchTitleScrollSpeed
        s.watchDateEnabled = settings?.watchDateEnabled ?? SettingsManager.Defaults.watchDateEnabled
        s.watchDateFormat = settings?.watchDateFormat ?? SettingsManager.Defaults.watchDateFormat
        s.artworkAccentColorHex = artworkAccentColorHex

        // Thumbnail availability
        s.hasThumbnail = watchThumbnailData != nil

        // Sleep timer state
        s.sleepTimerMode = sleepTimerMode
        s.sleepTimerRemainingSeconds = sleepTimerRemainingSeconds

        // Word cloud (top 10 words for current chapter)
        s.wordCloud = Array(currentChapterWordCloud.prefix(10))

        // Due flashcards
        if let db = databaseService {
            let cards: [Flashcard]
            do {
                cards = try FlashcardDAO(db: db.writer).allDueCards()
            } catch {
                os_log(.error, "Failed to load due flashcards for watch: %{public}@", error.localizedDescription)
                cards = []
            }
            if !cards.isEmpty {
                s.dueFlashcards = cards.map {
                    WatchFlashcard(id: $0.id, frontText: $0.frontText, backText: $0.backText)
                }
            }
        }

        return s
    }
}

#endif
