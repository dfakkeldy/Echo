import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
import WatchConnectivity
import UIKit
import os.log

// MARK: - Model

/// The central observable model managing audiobook playback, bookmarks,
/// chapter navigation, sleep timer, Watch connectivity, and Now Playing
/// metadata. Serves as the single source of truth for the player UI.
@Observable @MainActor
final class PlayerModel {
    // MARK: - Services

    let playbackController = PlaybackController()
    let watchSyncManager = WatchSyncManager()
    @ObservationIgnored private lazy var watchCommandRouter = WatchCommandRouter(
        facade: WatchConnectivityCoordinator(playerModel: self)
    )
    @ObservationIgnored let eventLogger = PlaybackEventLogger()

    var audioEngine: AudioEngine { playbackController.audioEngine }
    @ObservationIgnored weak var settingsManager: SettingsManager?
    let bookSettingsOverrideStore = BookSettingsOverrideStore()

    /// Convenience accessor for the shared playback state owned by PlaybackController.
    var state: PlaybackState { playbackController.state }

    // MARK: - Services (continued)

    @ObservationIgnored let playlistManager: PlaylistManager
    let transcriptService: TranscriptService
    let timelinePersistence = PlayerTimelinePersistenceService()

    // MARK: - UI state (local to PlayerModel)

    /// The currently selected tab (Listen, Read, or Timeline).
    var selectedTab: TabSelection = .nowPlaying

    /// Backward-compatible accessor — reads `true` when the Timeline tab is active.
    var showingTimeline: Bool {
        selectedTab == .timeline
    }

    /// When true, the timeline feed is frozen so the user can browse the EPUB
    /// column independently without the feed chasing playback position.
    var isTimelineFrozen: Bool = false

    /// Active bookmark draft used to present the edit bookmark modal.
    var activeBookmarkDraft: BookmarkDraft? = nil

    // MARK: - UI state (pass-through to PlaybackController)

    var loopMode: LoopMode {
        get { playbackController.loopMode }
        set { playbackController.loopMode = newValue }
    }
    var speed: Float {
        get { playbackController.speed }
        set { playbackController.speed = newValue }
    }
    var isVolumeBoostEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "global_volumeBoostEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "global_volumeBoostEnabled")
            playbackController.setVolumeBoost(enabled: resolvedVolumeBoostEnabled,
                                                gainDB: settingsManager?.volumeBoostGain ?? SettingsManager.Defaults.volumeBoostGain)
        }
    }

    // MARK: - Per-Book Settings Overrides (pass-through to BookSettingsOverrideStore)

    var bookFontOverride: String? {
        get { bookSettingsOverrideStore.bookFontOverride }
        set { bookSettingsOverrideStore.bookFontOverride = newValue }
    }

    var bookPlayBookmarksInlineOverride: String? {
        get { bookSettingsOverrideStore.bookPlayBookmarksInlineOverride }
        set { bookSettingsOverrideStore.bookPlayBookmarksInlineOverride = newValue }
    }

    var bookVolumeBoostOverride: String? {
        get { bookSettingsOverrideStore.bookVolumeBoostOverride }
        set { bookSettingsOverrideStore.bookVolumeBoostOverride = newValue }
    }

    var resolvedAppFont: String {
        BookPreferencesService.resolveAppFont(override: bookFontOverride, globalFont: settingsManager?.appFont)
    }

    var resolvedPlayBookmarksInline: Bool {
        BookPreferencesService.resolvePlayBookmarksInline(override: bookPlayBookmarksInlineOverride, globalValue: settingsManager?.playBookmarksInline)
    }

    var resolvedVolumeBoostEnabled: Bool {
        BookPreferencesService.resolveVolumeBoost(override: bookVolumeBoostOverride, globalEnabled: isVolumeBoostEnabled)
    }

    func updateBookFontOverride(_ value: String?) {
        bookFontOverride = value
        if let key = folderURL?.absoluteString {
            bookSettingsOverrideStore.persistFontOverride(value, for: key)
        }
    }

    func updateBookPlayBookmarksInlineOverride(_ value: String?) {
        bookPlayBookmarksInlineOverride = value
        if let key = folderURL?.absoluteString {
            bookSettingsOverrideStore.persistBookmarksInlineOverride(value, for: key)
        }
    }

    func updateBookVolumeBoostOverride(_ value: String?) {
        bookVolumeBoostOverride = value
        if let key = folderURL?.absoluteString {
            bookSettingsOverrideStore.persistVolumeBoostOverride(value, for: key)
        }
        playbackController.setVolumeBoost(enabled: resolvedVolumeBoostEnabled,
                                           gainDB: settingsManager?.volumeBoostGain ?? SettingsManager.Defaults.volumeBoostGain)
    }

    // MARK: - Sleep timer state (pass-through to SleepTimerManager)

    var sleepTimerMode: SleepTimerMode { sleepTimerManager.mode }
    var sleepTimerRemainingSeconds: Int { sleepTimerManager.remainingSeconds }

    // MARK: - Playlist state (pass-through to PlaybackState)

    var folderURL: URL? {
        get { state.folderURL }
        set { state.folderURL = newValue }
    }
    var tracks: [Track] {
        get { state.tracks }
        set { state.tracks = newValue }
    }
    var currentIndex: Int { state.currentIndex }

    // MARK: - Playback state (pass-through to PlaybackState)

    var isPlaying: Bool { state.isPlaying }
    var currentTitle: String { state.currentTitle }
    var currentSubtitle: String { state.currentSubtitle }
    var isManualSeeking: Bool { state.isManualSeeking }

    // MARK: - Progress (pass-through to PlaybackState)

    var progressFraction: Double { state.progressFraction }
    var progressText: String { state.progressText }
    var elapsedText: String { state.elapsedText }
    var durationSeconds: Double? { state.durationSeconds }
    var currentPlaybackTime: TimeInterval { audioEngine.currentTime }
    var thumbnailImage: UIImage? { state.thumbnailImage }
    var currentDisplayArtwork: UIImage? { state.currentDisplayArtwork }
    var currentDisplayArtworkVersion: Int { state.currentDisplayArtworkVersion }
    var watchThumbnailData: Data? { state.watchThumbnailData }

    // MARK: - Chapters (pass-through to PlaybackState)

    var chapters: [Chapter] {
        get { state.chapters }
        set { state.chapters = newValue }
    }
    
    var alignmentPickerChapters: [Chapter] {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            return state.aggregatedChapters.map { agg in
                Chapter(
                    index: agg.chapterIndex,
                    title: agg.chapterTitle.isEmpty ? "Chapter \(agg.chapterIndex + 1)" : agg.chapterTitle,
                    startSeconds: agg.startSeconds,
                    endSeconds: agg.endSeconds,
                    isEnabled: true
                )
            }
        }
        return state.chapters
    }
    var transcription: [TranscriptionSegment] {
        get { state.transcription }
        set { state.transcription = newValue }
    }
    var enhancedTranscription: [EnhancedTranscriptionSegment] {
        get { state.enhancedTranscription }
        set { state.enhancedTranscription = newValue }
    }
    var currentChapterIndex: Int? { state.currentChapterIndex }
    var chapterWordClouds: [Int: [WordFrequency]] {
        get { state.chapterWordClouds }
        set { state.chapterWordClouds = newValue }
    }
    var rollingWordClouds: [(startTime: TimeInterval, frequencies: [WordFrequency])] {
        get { state.rollingWordClouds }
        set { state.rollingWordClouds = newValue }
    }
    var currentChapterWordCloud: [WordFrequency] {
        guard let idx = state.currentChapterIndex else { return [] }
        return state.chapterWordClouds[idx] ?? []
    }

    /// The fine-grained sub-section atoms for the currently active logical chapter.
    /// Non-empty only for Libation-ripped M4Bs where chapter grouping was applied.
    /// Used by `PlayerScrubberView` to render hairline tick marks on the scrubber rail.
    var currentChapterSections: [Chapter] {
        guard let idx = state.currentChapterIndex else { return [] }
        return state.chapterSections[idx] ?? []
    }

    /// Whether EPUB blocks have been imported for the current audiobook.
    var hasEPUB: Bool {
        timelinePersistence.hasEPUB(for: folderURL?.absoluteString)
    }

    /// Whether transcript or enhanced transcript data is loaded for the current audiobook.
    var hasTranscript: Bool {
        !transcription.isEmpty || !enhancedTranscription.isEmpty
    }

    var isTranscriptProcessingEnabled: Bool {
        get { state.isTranscriptProcessingEnabled }
        set { state.isTranscriptProcessingEnabled = newValue }
    }

    // MARK: - Multi-M4B Aggregation (pass-through to PlaybackState)

    var isMultiM4B: Bool { state.isMultiM4B }
    var m4bBooks: [M4BBook] { state.m4bBooks }
    var aggregatedChapters: [AggregatedChapter] { state.aggregatedChapters }
    var totalBookDuration: TimeInterval { state.totalBookDuration }

    let snippetPlayer = SnippetPlayer()
    var isPlayingSnippet: Bool { snippetPlayer.isPlaying }

    var deepLinkHandler = DeepLinkHandler()
    let nowPlayingController = NowPlayingController()
    let bookmarkStore = BookmarkStore()
    let sleepTimerManager = SleepTimerManager()
    let artworkCoordinator = BookmarkArtworkCoordinator()
    let flashcardTriggerController = InlineFlashcardTriggerController()
    let progressPresenter = PlaybackProgressPresenter()
    let chapterLoadingCoordinator = ChapterLoadingCoordinator()
    let playerLoadingCoordinator = PlayerLoadingCoordinator()
    var continuousAlignmentService: ContinuousAlignmentService?

    private func computeWordClouds() {
        transcriptService.computeWordClouds()
    }

    // MARK: - Bookmarks

    /// All bookmarks for the currently loaded book, sorted by timestamp.
    var bookmarks: [Bookmark] { bookmarkStore.bookmarks }
    /// Whether a voice memo attached to a bookmark is currently playing in overlay mode.
    var isPlayingVoiceMemo: Bool { bookmarkStore.isPlayingVoiceMemo }
    /// 0...1 progress of the currently playing voice memo, for the overlay UI.
    var voiceMemoProgress: Double { bookmarkStore.voiceMemoProgress }

    /// The currently triggered inline flashcard, shown as an overlay during playback.
    var activeInlineCard: Flashcard? = nil
    /// Whether an inline flashcard overlay is currently presented.
    var isShowingInlineFlashcard: Bool { activeInlineCard != nil }

    /// Active playback session event ID for timeline logging.
    @ObservationIgnored var currentPlaybackEventID: String?
    /// UUID of the most recently triggered bookmark, used to prevent retrigger loops.
    @ObservationIgnored var lastTriggeredBookmarkID: UUID?
    /// Player time at which the most recent bookmark was triggered, used to suppress duplicate firings.
    @ObservationIgnored var lastTriggeredAtPlayerSecond: Double = -1
    /// The player time used during the last bookmark voice-memo trigger check.
    @ObservationIgnored var lastBookmarkCheckSecond: Double?

    /// Tracks the last track ID for which a thumbnail was sent to the watch,
    /// avoiding redundant heavy image transfers on every periodic sync.

    /// The display scale used for thumbnail rendering. Set from the SwiftUI
    /// environment to avoid `UIScreen.main` deprecation on iOS 26+.
    var displayScale: CGFloat = 2.0

    /// Sets the display scale used for thumbnail rendering.
    /// Called from the SwiftUI environment to avoid `UIScreen.main` on iOS 26+.
    /// - Parameter scale: The display scale factor (e.g. 2.0 or 3.0).
    func setDisplayScale(_ scale: CGFloat) {
        displayScale = scale
    }

    func setSettingsManager(_ settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    // MARK: - Playback infrastructure

    /// Background task claim held during pause to reduce the chance of eviction
    /// from the system Now Playing slot.
    private var pauseBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    /// Tracks if audio was playing prior to an interruption, to determine if we should resume.
    var wasPlayingBeforeInterruption: Bool = false

    // MARK: - Security-scoped access (delegated to SecurityScopeManager)

    let persistence = Persistence()
    let securityScope = SecurityScopeManager()

    /// Current app-level output gain in dB, used for watch crown volume control.
    /// Not observable — gain changes don't trigger view re-renders.
    @ObservationIgnored private var _outputGain: Float = 0

    // MARK: - Watch command support (accessed by WatchConnectivityCoordinator)

    var watchCommandOutputGain: Float { _outputGain }

    var crownScrubSensitivity: Double {
        settingsManager?.crownScrubSensitivity ?? SettingsManager.Defaults.crownScrubSensitivity
    }

    var crownVolumeSensitivity: Double {
        settingsManager?.crownVolumeSensitivity ?? SettingsManager.Defaults.crownVolumeSensitivity
    }

    func setWatchCommandOutputGain(_ gain: Float) {
        _outputGain = gain
        audioEngine.setGain(gain)
    }

    func addBookmarkFromWatchCommand() {
        _ = addBookmarkAtCurrentTime()
    }

    func gradeFlashcard(cardID: String, grade: Int) {
        guard let writer = databaseService?.writer else {
            os_log(.error, "gradeFlashcard: no database writer available")
            return
        }
        do {
            try FlashcardDAO(db: writer).grade(cardID: cardID, grade: grade)
        } catch {
            os_log(.error, "gradeFlashcard failed for %{public}@: %{public}@", cardID, error.localizedDescription)
        }
    }

    /// Optional database service for SQL persistence.
    /// Set externally to enable SQL-backed bookmark storage.
    var databaseService: DatabaseService? {
        get { timelinePersistence.databaseService }
        set {
            timelinePersistence.databaseService = newValue
            configureContinuousAlignment()
        }
    }

    /// Optional timeline service for event logging.
    /// Set externally when the Timeline tab is active.
    var timelineService: TimelineService?

    init() {
        SettingsManager.registerDefaults()

        playlistManager = PlaylistManager(state: playbackController.state, persistence: persistence)
        transcriptService = TranscriptService(state: playbackController.state)
        playbackController.delegate = self

        watchSyncManager.onMessage = { [weak self] message, reply in
            self?.watchCommandRouter.route(message: message, replyHandler: reply)
        }
        watchSyncManager.onReceiveApplicationContext = { [weak self] context in
            self?.watchCommandRouter.route(message: context)
        }
        watchSyncManager.onReceiveFile = { [weak self] file in
            self?.watchCommandRouter.handleFile(file)
        }
        watchSyncManager.stateProvider = { [weak self] in
            self?.watchStateContext() ?? [:]
        }
        watchSyncManager.thumbnailProvider = { [weak self] in
            guard let self, self.state.tracks.indices.contains(self.currentIndex) else {
                return (nil, nil)
            }
            return (self.artworkCoordinator.currentArtworkSyncKey, self.state.watchThumbnailData)
        }

        bookmarkStore.onPersist = { [weak self] bookmarks in
            guard let self, let key = bookmarksStorageKey else { return }
            persistence.saveBookmarks(bookmarks, for: key, folderURL: folderURL)
        }
        bookmarkStore.onDeleteFile = { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                os_log(.error, "Failed to remove file: %{private}@", error.localizedDescription)
            }
        }
        bookmarkStore.onBookmarksChanged = { [weak self] in
            guard let self else { return }
            artworkCoordinator.invalidateCache()
            artworkCoordinator.updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
            if loopMode == .bookmark && currentTrackBookmarks.isEmpty {
                setLoopMode(.off)
            }
        }
        bookmarkStore.storageKeyProvider = { [weak self] in self?.bookmarksStorageKey }
        bookmarkStore.onSwitchToVoiceMemo = { [weak self] in
            self?.prepareAudioForVoiceMemo()
        }
        bookmarkStore.onSwitchToMainPlayer = { [weak self] in
            guard let self else { return }
            self.bookmarkStore.stopVoiceMemo()
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setActive(true)
            if self.isPlaying {
                self.audioEngine.playImmediately(atRate: self.speed)
                self.playbackController.applySpeedToCurrentItem()
                self.updateNowPlayingInfo(isPaused: false)
            }
        }

        snippetPlayer.onPlaybackWillStart = { [weak self] in
            self?.prepareAudioForVoiceMemo()
        }
        snippetPlayer.onPlaybackDidEnd = { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setActive(true)
            if self.isPlaying {
                self.audioEngine.playImmediately(atRate: self.speed)
                self.playbackController.applySpeedToCurrentItem()
                self.updateNowPlayingInfo(isPaused: false)
            }
        }

        sleepTimerManager.onFire = { [weak self] in
            guard let self else { return }
            if self.isPlaying { self.pause() }
            self.syncToWatch()
        }
        sleepTimerManager.onTick = { [weak self] in
            self?.syncToWatch()
        }

        // Wire artwork coordinator dependencies.
        artworkCoordinator.state = state
        artworkCoordinator.bookmarkProvider = { [weak self] in self?.bookmarkStore.bookmarks ?? [] }
        artworkCoordinator.folderURLProvider = { [weak self] in self?.folderURL }
        artworkCoordinator.trackIDProvider = { [weak self] in
            guard let self, self.state.tracks.indices.contains(self.currentIndex) else { return nil }
            return self.state.tracks[self.currentIndex].id
        }
        artworkCoordinator.isPlayingProvider = { [weak self] in self?.isPlaying ?? false }
        artworkCoordinator.currentPlaybackTimeProvider = { [weak self] in self?.currentPlaybackTime ?? 0 }
        artworkCoordinator.onUpdateNowPlaying = { [weak self] isPaused in
            self?.updateNowPlayingInfo(isPaused: isPaused)
        }
        artworkCoordinator.onSyncToWatch = { [weak self] in
            self?.syncToWatch()
        }

        // Wire flashcard trigger controller dependencies.
        flashcardTriggerController.databaseServiceProvider = { [weak self] in self?.databaseService }
        flashcardTriggerController.trackKeyProvider = { [weak self] in
            guard let self, self.state.tracks.indices.contains(self.currentIndex) else { return "" }
            return self.state.tracks[self.currentIndex].url.lastPathComponent
        }
        flashcardTriggerController.isPlayingProvider = { [weak self] in self?.isPlaying ?? false }
        flashcardTriggerController.isManualSeekingProvider = { [weak self] in self?.isManualSeeking ?? false }
        flashcardTriggerController.loopModeProvider = { [weak self] in self?.loopMode ?? .off }

        // Wire progress presenter dependencies.
        progressPresenter.state = state
        progressPresenter.audioEngine = audioEngine
        progressPresenter.nowPlayingController = nowPlayingController
        progressPresenter.speedProvider = { [weak self] in self?.speed ?? 1.0 }
        progressPresenter.currentTitleProvider = { [weak self] in self?.currentTitle ?? "" }
        progressPresenter.currentSubtitleProvider = { [weak self] in self?.currentSubtitle ?? "" }
        progressPresenter.currentDisplayArtworkProvider = { [weak self] in self?.currentDisplayArtwork }
        progressPresenter.thumbnailImageProvider = { [weak self] in self?.thumbnailImage }
        progressPresenter.onSyncToWatch = { [weak self] in self?.syncToWatch() }
        progressPresenter.onChapterOutOfBounds = { [weak self] in
            self?.chapterLoadingCoordinator.updateCurrentChapterFromPlayerTime()
        }

        // Wire chapter loading coordinator dependencies.
        chapterLoadingCoordinator.state = state
        chapterLoadingCoordinator.audioEngine = audioEngine
        chapterLoadingCoordinator.persistence = persistence
        chapterLoadingCoordinator.timelinePersistence = timelinePersistence
        chapterLoadingCoordinator.isPlayingProvider = { [weak self] in self?.isPlaying ?? false }
        chapterLoadingCoordinator.databaseServiceProvider = { [weak self] in self?.databaseService }
        chapterLoadingCoordinator.onUpdateNowPlayingInfo = { [weak self] isPaused in
            self?.progressPresenter.updateNowPlayingInfo(isPaused: isPaused)
        }
        chapterLoadingCoordinator.onSyncToWatch = { [weak self] in self?.syncToWatch() }
        chapterLoadingCoordinator.onUpdateProgress = { [weak self] in self?.progressPresenter.updateProgress() }
        chapterLoadingCoordinator.onComputeWordClouds = { [weak self] in self?.computeWordClouds() }
        chapterLoadingCoordinator.onDurationLoaded = { [weak self] seconds in
            guard let self else { return }
            if self.deepLinkHandler.pendingSeekTime != nil {
                Task { @MainActor in
                    if let action = self.deepLinkHandler.applyPendingSeekIfPossible(isItemLoaded: self.audioEngine.isItemLoaded),
                       case .seek(let time) = action {
                        self.seek(toSeconds: time)
                    }
                }
            } else if let folder = self.folderURL?.absoluteString,
                      let progress = self.persistence.getBookProgress(for: folder),
                      self.state.tracks.indices.contains(self.currentIndex),
                      progress.trackId == self.state.tracks[self.currentIndex].id,
                      progress.time > 0, progress.time < seconds {
                let savedTime = progress.time
                Task { @MainActor in
                    self.state.isManualSeeking = true
                    self.audioEngine.seek(to: savedTime) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.state.isManualSeeking = false
                            self?.chapterLoadingCoordinator.updateCurrentChapterFromPlayerTime()
                            self?.progressPresenter.updateElapsedTime()
                            self?.progressPresenter.updateProgress()
                            if let self, self.isPlaying {
                                self.audioEngine.playImmediately(atRate: self.speed)
                                self.playbackController.applySpeedToCurrentItem()
                            }
                        }
                    }
                }
            }
        }

        // Wire player loading coordinator dependencies.
        playerLoadingCoordinator.state = state
        playerLoadingCoordinator.audioEngine = audioEngine
        playerLoadingCoordinator.playbackController = playbackController
        playerLoadingCoordinator.playlistManager = playlistManager
        playerLoadingCoordinator.persistence = persistence
        playerLoadingCoordinator.timelinePersistence = timelinePersistence
        playerLoadingCoordinator.bookSettingsOverrideStore = bookSettingsOverrideStore
        playerLoadingCoordinator.securityScope = securityScope
        playerLoadingCoordinator.artworkCoordinator = artworkCoordinator
        playerLoadingCoordinator.flashcardTriggerController = flashcardTriggerController
        playerLoadingCoordinator.bookmarkStore = bookmarkStore
        playerLoadingCoordinator.progressPresenter = progressPresenter
        playerLoadingCoordinator.chapterLoadingCoordinator = chapterLoadingCoordinator
        playerLoadingCoordinator.watchSyncManager = watchSyncManager
        playerLoadingCoordinator.transcriptService = transcriptService
        playerLoadingCoordinator.nowPlayingController = nowPlayingController
        playerLoadingCoordinator.deepLinkHandler = deepLinkHandler
        playerLoadingCoordinator.databaseServiceProvider = { [weak self] in self?.databaseService }
        playerLoadingCoordinator.resolvedVolumeBoostEnabledProvider = { [weak self] in self?.resolvedVolumeBoostEnabled ?? false }
        playerLoadingCoordinator.defaultPlaybackSpeedProvider = { [weak self] in
            Float(self?.settingsManager?.defaultPlaybackSpeed ?? SettingsManager.Defaults.defaultPlaybackSpeed)
        }
        playerLoadingCoordinator.onConfigureRemoteCommands = { [weak self] in self?.configureRemoteCommandsIfNeeded() }
        playerLoadingCoordinator.onPersistSelection = { [weak self] url in self?.persistSelection(url: url) }
        playerLoadingCoordinator.onResetBookmarkCheckSecond = { [weak self] in self?.lastBookmarkCheckSecond = nil }
        playerLoadingCoordinator.onConfigureContinuousAlignment = { [weak self] in self?.configureContinuousAlignment() }

        // Wire PlaybackController coordination closures.
        playbackController.coordinator_seekBackwardDuration = { [weak self] in
            Double(self?.settingsManager?.seekBackwardDuration ?? SettingsManager.Defaults.seekBackwardDuration)
        }
        playbackController.coordinator_seekForwardDuration = { [weak self] in
            Double(self?.settingsManager?.seekForwardDuration ?? SettingsManager.Defaults.seekForwardDuration)
        }

        playbackController.coordinator_smartRewind = { [weak self] pausedDuration in
            self?.smartRewindAmount(for: pausedDuration) ?? 0
        }
        playbackController.coordinator_jumpToChapterStartForHours = { [weak self] pausedDuration in
            self?.shouldJumpToChapterStartForHoursLevel(pausedDuration: pausedDuration) ?? false
        }
        playbackController.coordinator_loadTrack = { [weak self] index, autoplay in
            self?.playerLoadingCoordinator.prepareToPlay(index: index, autoplay: autoplay)
        }
        playbackController.coordinator_persistAndSync = { [weak self] isPaused in
            self?.updateNowPlayingInfo(isPaused: isPaused)
            self?.syncToWatch()
        }
        playbackController.coordinator_checkVoiceMemo = { [weak self] at, prev in
            self?.checkVoiceMemoTrigger(at: at, previousSeconds: prev)
        }
        playbackController.coordinator_seekCompleted = { [weak self] isManual in
            if !isManual {
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        playbackController.coordinator_persistSpeed = { [weak self] key, speed in
            self?.persistence.saveSpeed(for: key, speed: speed)
        }
        playbackController.coordinator_persistLoopMode = { [weak self] key, mode in
            self?.persistence.saveLoopMode(for: key, loopMode: mode)
        }
        playbackController.coordinator_hasBookmarks = { [weak self] in
            !(self?.bookmarkStore.bookmarks.isEmpty ?? true)
        }
        playbackController.coordinator_refreshProgress = { [weak self] in
            self?.updateNowPlayingElapsedTime()
            self?.updateProgressFromPlayer()
        }
        playbackController.coordinator_enabledBookmarks = { [weak self] in
            self?.enabledCurrentTrackBookmarks ?? []
        }
        playbackController.coordinator_jumpToBookmark = { [weak self] bookmark in
            self?.jumpToBookmark(bookmark)
        }
        playbackController.coordinator_refreshArtwork = { [weak self] at, force in
            self?.artworkCoordinator.updateCurrentDisplayArtwork(at: at, force: force)
        }
        playbackController.coordinator_endBackgroundTask = { [weak self] in
            self?.endBackgroundTask()
        }
        playbackController.coordinator_saveProgress = { [weak self] folder, trackId, time in
            self?.persistence.saveBookProgress(for: folder, trackId: trackId, time: time)
        }
        playbackController.coordinator_stopSecurityScope = { [weak self] in
            self?.stopCurrentFileSecurityScopeIfNeeded()
        }
        playbackController.coordinator_handleChapterEndSleepTimer = { [weak self] in
            guard let self else { return false }
            if case .endOfChapter = self.sleepTimerMode {
                self.sleepTimerManager.evaluateAtChapterEnd()
                return true
            }
            return false
        }
        playbackController.coordinator_currentTrackBookmarks = { [weak self] in
            self?.currentTrackBookmarks ?? []
        }
        playbackController.coordinator_isRewindEnabled = { [weak self] in
            self?.settingsManager?.isRewindEnabled ?? SettingsManager.Defaults.isRewindEnabled
        }
        playbackController.coordinator_configureAudioSession = { [weak self] in
            self?.configureAudioSessionIfNeeded()
        }
        playbackController.coordinator_startSecurityScope = { [weak self] in
            self?.startSelectionSecurityScopeIfNeeded()
            self?.startCurrentFileSecurityScopeIfNeeded()
        }
        playbackController.coordinator_playStateChanged = { [weak self] isPlaying in
            if isPlaying {
                self?.startPlaybackSessionLogging()
                if self?.settingsManager?.continuousAutoAlignmentEnabled == true {
                    self?.continuousAlignmentService?.start()
                }
            } else {
                self?.endPlaybackSessionLogging()
                self?.continuousAlignmentService?.stop()
            }
        }
        playlistManager.coordinator_postResetRefresh = { [weak self] in
            self?.updateCurrentChapterFromPlayerTime()
        }
    }

    /// Delegates to `WatchSyncManager.syncToWatch()`.
    func syncToWatch() {
        watchSyncManager.syncToWatch()
    }

    deinit {
        // Synchronous teardown on the MainActor instead of a fire-and-forget Task.
        // PlayerModel is @MainActor, so the deinit runs on the main actor.
        MainActor.assumeIsolated {
            audioEngine.cleanup()
            bookmarkStore.stopVoiceMemo()
            if pauseBackgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(pauseBackgroundTask)
            }
            stopAllSecurityScope()
        }
    }

    // MARK: Folder + track loading

    /// Reorders tracks within the playlist and persists the new order.
    /// - Parameters:
    ///   - source: The indices of tracks to move.
    ///   - destination: The index to insert the tracks at.
    func moveTracks(from source: IndexSet, to destination: Int) {
        playlistManager.moveTracks(from: source, to: destination)
    }

    func moveChapters(from source: IndexSet, to destination: Int) {
        playlistManager.moveChapters(from: source, to: destination)
    }

    func toggleTrackEnabled(at index: Int) {
        playlistManager.toggleTrackEnabled(at: index)
    }

    func toggleChapterEnabled(at index: Int) {
        playlistManager.toggleChapterEnabled(at: index)
    }

    func resetPlaylist() {
        playlistManager.resetPlaylist()
    }

    /// Loads a folder or single audio file as the active playlist. If the URL is a
    /// directory, all supported audio files are enumerated and sorted; if a single
    /// file, it becomes the sole track. Stops any current playback first.
    /// - Parameters:
    ///   - url: The folder or file URL to load.
    ///   - autoplay: Whether to automatically begin playback after loading. Defaults to `true`.
    func loadFolder(_ url: URL, autoplay: Bool = true) {
        playerLoadingCoordinator.loadFolder(url, autoplay: autoplay)
    }

    /// Restores the last selected folder or file from a security-scoped bookmark,


    /// Re-ingests timeline items for the current audiobook, reloading EPUB blocks
    /// and anchors from the database. Call after EPUB import or anchor changes.
    func reingestTimelineFromEPUB() async {
        guard let audiobookID = folderURL?.absoluteString else { return }
        let audioURL: URL = {
            if state.tracks.indices.contains(currentIndex) {
                return state.tracks[currentIndex].url
            }
            return folderURL ?? URL(fileURLWithPath: "/")
        }()
        await timelinePersistence.reingestTimelineFromEPUB(
            audiobookID: audiobookID,
            audioURL: audioURL,
            chapters: state.chapters,
            transcription: state.transcription,
            enhancedTranscription: state.enhancedTranscription,
            folderURL: folderURL
        )
    }

    /// Restores the last selected folder or file from a security-scoped bookmark,
    /// loading it without autoplay. Falls back to sample content in DEBUG simulator
    /// builds when no persisted selection exists.
    func restoreLastSelectionIfPossible() {
        guard let url = persistence.restoreBookmark() else {
            #if DEBUG && targetEnvironment(simulator)
            if let sampleURL = MockMediaProvider.sampleAudiobookURL() {
                loadFolder(sampleURL, autoplay: false)
            }
            #endif
            return
        }
        loadFolder(url, autoplay: false)
    }

    /// Sets up or tears down the continuous alignment service.
    func configureContinuousAlignment() {
        guard let db = databaseService?.writer, let audiobookID = folderURL?.absoluteString else {
            continuousAlignmentService?.stop()
            continuousAlignmentService = nil
            return
        }
        if continuousAlignmentService == nil {
            continuousAlignmentService = ContinuousAlignmentService(audioEngine: audioEngine, db: db, audiobookID: audiobookID)
        }
        
        if isPlaying && settingsManager?.continuousAutoAlignmentEnabled == true {
            continuousAlignmentService?.start()
        } else {
            continuousAlignmentService?.stop()
        }
    }

    func handleDeepLink(_ deepLink: PlayerDeepLink) {
        guard let action = deepLinkHandler.handle(deepLink, isItemLoaded: audioEngine.isItemLoaded, isPlaying: isPlaying) else { return }
        switch action {
        case .play:
            play()
        case .seek(let time):
            seek(toSeconds: time)
        case .queueSeek:
            break
        }
    }

    // MARK: Playback controls

    private func smartRewindAmount(for pausedDuration: TimeInterval) -> Double {
        let settings = settingsManager

        let secondsThreshold = settings?.rewindPauseSecondsThreshold ?? SettingsManager.Defaults.rewindPauseSecondsThreshold
        let secondsAmount = settings?.rewindAmountAfterSeconds ?? SettingsManager.Defaults.rewindAmountAfterSeconds

        let minutesThreshold = settings?.rewindPauseMinutesThreshold ?? SettingsManager.Defaults.rewindPauseMinutesThreshold
        let minutesAmount = settings?.rewindAmountAfterMinutes ?? SettingsManager.Defaults.rewindAmountAfterMinutes

        let hoursThreshold = settings?.rewindPauseHoursThreshold ?? SettingsManager.Defaults.rewindPauseHoursThreshold
        let hoursAmount = settings?.rewindAmountAfterHours ?? SettingsManager.Defaults.rewindAmountAfterHours

        var rewindAmount = 0
        if pausedDuration >= Double(secondsThreshold) {
            rewindAmount = secondsAmount
        }
        if pausedDuration >= Double(minutesThreshold * 60) {
            rewindAmount = minutesAmount
        }
        if pausedDuration >= Double(hoursThreshold * 3600) {
            rewindAmount = hoursAmount
        }

        // Backward compatibility with previous single-level rewind settings.
        if rewindAmount == 0 {
            let defaults = UserDefaults.standard
            let legacyThreshold = defaults.integer(forKey: "rewindPauseDuration")
            let legacyAmount = defaults.integer(forKey: "rewindAmount")
            if legacyThreshold > 0, pausedDuration >= Double(legacyThreshold) {
                rewindAmount = legacyAmount
            }
        }

        return Double(rewindAmount)
    }

    private func shouldJumpToChapterStartForHoursLevel(pausedDuration: TimeInterval) -> Bool {
        let settings = settingsManager
        let hoursThreshold = settings?.rewindPauseHoursThreshold ?? SettingsManager.Defaults.rewindPauseHoursThreshold
        let hoursToChapterStart = settings?.rewindHoursToChapterStart ?? SettingsManager.Defaults.rewindHoursToChapterStart
        return hoursToChapterStart && pausedDuration >= Double(hoursThreshold * 3600)
    }

    func togglePlayPause() {
        playbackController.togglePlayPause()
    }

    func play() {
        playbackController.play()
    }

    func pause() {
        startPauseBackgroundTask()
        playbackController.pause()
    }

    private func startPauseBackgroundTask() {
        guard pauseBackgroundTask == .invalid else { return }
        pauseBackgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard pauseBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pauseBackgroundTask)
        pauseBackgroundTask = .invalid
    }

    func nextTrack() {
        playbackController.nextTrack()
    }

    func previousTrackOrRestart() {
        playbackController.previousTrackOrRestart()
    }

    func nextChapter() {
        playbackController.nextChapter()
    }

    func previousChapterOrRestart() {
        playbackController.previousChapterOrRestart()
    }

    func nextSection() {
        playbackController.nextSection()
    }

    func previousSectionOrRestart() {
        playbackController.previousSectionOrRestart()
    }

    private var enabledCurrentTrackBookmarks: [Bookmark] {
        currentTrackBookmarks.filter { $0.isEnabled && $0.timestamp.isFinite }
    }

    @discardableResult
    func skipBackwardNavigation() -> Bool {
        playbackController.skipBackwardNavigation()
    }

    @discardableResult
    func skipForwardNavigation() -> Bool {
        playbackController.skipForwardNavigation()
    }

    @discardableResult
    func skipBackward30() -> Bool {
        playbackController.skipBackward30()
    }

    @discardableResult
    func skipForward30() -> Bool {
        playbackController.skipForward30()
    }

    func seek(toSeconds targetSeconds: Double) {
        playbackController.seek(toSeconds: targetSeconds)
    }

    func seek(toFraction fraction: Double) {
        playbackController.seek(toFraction: fraction)
    }

    func setSpeed(_ newSpeed: Float) {
        playbackController.setSpeed(newSpeed)
    }

    func setVolumeBoost(enabled: Bool) {
        isVolumeBoostEnabled = enabled
    }

    func setLoopMode(_ mode: LoopMode) {
        playbackController.setLoopMode(mode)
    }

    func cycleLoopMode() {
        playbackController.cycleLoopMode()
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ mode: SleepTimerMode) {
        sleepTimerManager.setTimer(mode)
        syncToWatch()
    }

    func cancelSleepTimer() {
        sleepTimerManager.cancel()
        syncToWatch()
    }

    func stop() {
        playbackController.stop()
    }

    private func configureAudioSessionIfNeeded() {
        audioEngine.configureAudioSession()
    }

    // MARK: Security-scoped resource handling

    private func startSelectionSecurityScopeIfNeeded() {
        guard let url = folderURL else { return }
        securityScope.startSelection(url: url)
    }

    private func stopSelectionSecurityScopeIfNeeded() {
        securityScope.stopSelection()
    }

    private func startCurrentFileSecurityScopeIfNeeded() {
        guard state.tracks.indices.contains(currentIndex) else { return }
        securityScope.startFile(url: state.tracks[currentIndex].url)
    }

    private func startCurrentFileSecurityScopeForURL(_ url: URL) {
        securityScope.startFile(url: url)
    }

    private func stopCurrentFileSecurityScopeIfNeeded() {
        securityScope.stopFile()
    }

    private func stopAllSecurityScope() {
        securityScope.stopAll()
    }

    // MARK: Now Playing + Remote controls (Apple Watch / Control Center)

    private func configureRemoteCommandsIfNeeded() {
        nowPlayingController.configureRemoteCommands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextTrack: { [weak self] in self?.skipForwardNavigation() },
            skipBackward: { [weak self] in self?.skipBackward30() },
            skipForward: { [weak self] in self?.skipForward30() },
            previousTrack: { [weak self] in self?.skipBackwardNavigation() },
            seek: { [weak self] position in self?.seek(toSeconds: position) },
            skipBackwardInterval: settingsManager?.seekBackwardDuration ?? SettingsManager.Defaults.seekBackwardDuration,
            skipForwardInterval: settingsManager?.seekForwardDuration ?? SettingsManager.Defaults.seekForwardDuration
        )
    }

    func updateNowPlayingElapsedTime() {
        progressPresenter.updateElapsedTime()
    }

    func updateNowPlayingInfo(isPaused: Bool) {
        progressPresenter.updateNowPlayingInfo(isPaused: isPaused)
    }

    func updateProgressFromPlayer() {
        progressPresenter.updateProgress()
    }


    private func loadDurationForNowPlaying() async {
        await chapterLoadingCoordinator.loadDurationForNowPlaying()
    }


    private func loadChaptersForCurrentItem() async {
        await chapterLoadingCoordinator.loadChaptersForCurrentItem()
    }

    func updateCurrentChapterFromPlayerTime() {
        chapterLoadingCoordinator.updateCurrentChapterFromPlayerTime()
    }

    // MARK: Audio Source Switching

    /// Configures the AVAudioSession for voice memo overlay playback.
    /// Called by BookmarkStore via `onSwitchToVoiceMemo` callback.
    private func prepareAudioForVoiceMemo() {
        audioEngine.pause()
        updateNowPlayingInfo(isPaused: true)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    /// Restores the AVAudioSession for main player playback.
    /// Called by BookmarkStore via `onSwitchToMainPlayer` callback.
    private func resumeAudioForMainPlayer() {
        bookmarkStore.stopVoiceMemo()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    /// Stops the currently playing voice memo overlay and resumes main playback.
    func stopVoiceMemo() {
        bookmarkStore.stopVoiceMemo()
        resumeAudioForMainPlayer()
        audioEngine.playImmediately(atRate: speed)
        playbackController.applySpeedToCurrentItem()
        updateNowPlayingInfo(isPaused: false)
    }

    /// Delegates to BookmarkStore to detect and fire inline voice memo triggers.
    func checkVoiceMemoTrigger(at currentSeconds: Double, previousSeconds: Double?) {
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        if let memoURL = bookmarkStore.checkVoiceMemoTrigger(
            at: currentSeconds,
            previousSeconds: previousSeconds,
            isPlaying: isPlaying,
            isManualSeeking: isManualSeeking,
            loopMode: loopMode,
            playBookmarksInline: resolvedPlayBookmarksInline,
            trackId: trackId,
            folderURL: folderURL,
            lastTriggeredBookmarkID: &lastTriggeredBookmarkID,
            lastTriggeredAtPlayerSecond: &lastTriggeredAtPlayerSecond
        ) {
            bookmarkStore.startVoiceMemoPlayback(url: memoURL)
        }
    }

    // MARK: - Inline Flashcard wrappers

    /// Grades the currently shown inline flashcard and resumes playback.
    func gradeInlineFlashcard(_ grade: Int) {
        guard let card = activeInlineCard else { return }
        flashcardTriggerController.gradeCard(grade, cardID: card.id)
        activeInlineCard = nil
        if flashcardTriggerController.wasPlayingBeforeFlashcard {
            flashcardTriggerController.wasPlayingBeforeFlashcard = false
            audioEngine.playImmediately(atRate: speed)
            playbackController.applySpeedToCurrentItem()
        }
    }

    /// Dismisses the inline flashcard overlay without grading, resuming playback.
    func dismissInlineFlashcard() {
        activeInlineCard = nil
        if flashcardTriggerController.wasPlayingBeforeFlashcard {
            flashcardTriggerController.wasPlayingBeforeFlashcard = false
            audioEngine.playImmediately(atRate: speed)
            playbackController.applySpeedToCurrentItem()
        }
    }

    private func persistSelection(url: URL) {
        // Refresh security scope for the new selection.
        securityScope.stopSelection()
        securityScope.startSelection(url: url)

        // Save security-scoped bookmark so it restores after relaunch.
        persistence.saveBookmark(url: url)

        // Load bookmarks for this book.
        loadBookmarksForCurrentBook()
    }
}
