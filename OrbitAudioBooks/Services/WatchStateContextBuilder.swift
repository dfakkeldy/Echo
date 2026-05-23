import Foundation

// MARK: - Watch State Snapshot

/// A value-type snapshot of all state needed to build the watch context dictionary.
/// Decouples state gathering (PlayerModel) from dictionary serialization (builder).
struct WatchStateSnapshot {
    // MARK: Playback state
    var isPlaying: Bool = false
    var progressFraction: Double = 0
    var currentPlaybackTime: TimeInterval = 0
    var currentIndex: Int = 0
    var trackCount: Int = 0
    var currentTrackId: String?
    var durationSeconds: Double?

    // MARK: Display title
    var chapterCount: Int = 0
    var currentSubtitle: String = ""
    var currentTitle: String = ""
    var currentChapterIndex: Int?

    // MARK: Storage keys
    var bookmarkStorageKey: String?
    var folderKey: String?

    // MARK: Settings values (pre-resolved from SettingsManager)
    var crownAction: String = SettingsManager.Defaults.crownAction
    var isHapticFeedbackEnabled: Bool = SettingsManager.Defaults.isHapticFeedbackEnabled
    var watchQuickBookmarkTimeoutSeconds: Int = SettingsManager.Defaults.watchQuickBookmarkTimeoutSeconds
    var loopModeRawValue: String = LoopMode.off.rawValue
    var playbackSpeed: Double = 1.0
    var watchPage1Data: Data = Data()
    var watchPage2Data: Data = Data()
    var linearBarMode: String = SettingsManager.Defaults.linearBarMode
    var linearBarHidden: Bool = SettingsManager.Defaults.linearBarHidden
    var circularRingMode: String = SettingsManager.Defaults.circularRingMode
    var circularRingHidden: Bool = SettingsManager.Defaults.circularRingHidden
    var watchArtworkLayout: String = SettingsManager.Defaults.watchArtworkLayout
    var watchBackgroundStyle: String = SettingsManager.Defaults.watchBackgroundStyle

    // MARK: Thumbnail availability
    var hasThumbnail: Bool = false

    // MARK: Sleep timer state
    var sleepTimerMode: SleepTimerMode = .off
    var sleepTimerRemainingSeconds: Int = 0

    // MARK: Word cloud (top 10 words for current chapter, pre-filtered by caller)
    var wordCloud: [WordFrequency] = []

    // MARK: Due flashcards (pre-fetched by caller)
    var dueFlashcards: [WatchFlashcard] = []
}

// MARK: - Watch State Context Builder

enum WatchStateContextBuilder {
    /// Builds the watch application context dictionary from a snapshot.
    /// Pure function: no side effects, no external dependencies.
    static func build(from s: WatchStateSnapshot) -> [String: Any] {
        var context: [String: Any] = [:]

        // Playback state
        context["isPlaying"] = s.isPlaying
        context["progressFraction"] = s.progressFraction
        context["currentTime"] = s.currentPlaybackTime
        context["bookmarkStorageKey"] = s.bookmarkStorageKey
        context["folderKey"] = s.folderKey
        if let trackId = s.currentTrackId {
            context["trackId"] = trackId
        }

        // Title
        let title: String = if s.chapterCount >= 2 {
            s.currentSubtitle.isEmpty
                ? String(localized: "Chapter \((s.currentChapterIndex ?? 0) + 1)")
                : s.currentSubtitle
        } else {
            s.currentTitle
        }
        context["title"] = title

        // Total progress
        if let duration = s.durationSeconds, duration.isFinite, duration > 0 {
            let totalElapsed = s.currentPlaybackTime
            context["totalProgressFraction"] = min(1, max(0, totalElapsed / duration))
            context["totalBookDuration"] = duration
        } else {
            let totalCount = Double(s.trackCount)
            context["totalProgressFraction"] = totalCount > 0
                ? (Double(s.currentIndex) + s.progressFraction) / totalCount : 0.0
        }

        // Settings
        context["crownAction"] = s.crownAction
        context["isHapticFeedbackEnabled"] = s.isHapticFeedbackEnabled
        context["watchQuickBookmarkTimeoutSeconds"] = s.watchQuickBookmarkTimeoutSeconds
        context["loopMode"] = s.loopModeRawValue
        context["playbackSpeed"] = s.playbackSpeed
        context["watchPage1"] = s.watchPage1Data
        context["watchPage2"] = s.watchPage2Data
        context["linearBarMode"] = s.linearBarMode
        context["linearBarHidden"] = s.linearBarHidden
        context["circularRingMode"] = s.circularRingMode
        context["circularRingHidden"] = s.circularRingHidden
        context["watchArtworkLayout"] = s.watchArtworkLayout
        context["watchBackgroundStyle"] = s.watchBackgroundStyle
        context["hasThumbnail"] = s.hasThumbnail

        // Sleep timer
        switch s.sleepTimerMode {
        case .off:
            context["sleepTimerMode"] = "off"
            context["sleepTimerRemainingSeconds"] = 0
        case .minutes(let mins):
            context["sleepTimerMode"] = "minutes"
            context["sleepTimerMinutes"] = mins
            context["sleepTimerRemainingSeconds"] = s.sleepTimerRemainingSeconds
        case .endOfChapter:
            context["sleepTimerMode"] = "endOfChapter"
            context["sleepTimerRemainingSeconds"] = 0
        }

        // Word cloud (top 10)
        let cloud = s.wordCloud.prefix(10)
        if !cloud.isEmpty, let jsonData = try? JSONEncoder().encode(Array(cloud)),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            context["wordCloudJSON"] = jsonString
            context["wordCloudChapterIndex"] = s.currentChapterIndex ?? 0
        }

        // Due flashcards
        if !s.dueFlashcards.isEmpty,
           let data = try? JSONEncoder().encode(s.dueFlashcards),
           let json = String(data: data, encoding: .utf8) {
            context["dueCardsJSON"] = json
        }

        return context
    }
}
