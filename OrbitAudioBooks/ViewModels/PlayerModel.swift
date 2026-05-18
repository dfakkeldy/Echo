import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
import WatchConnectivity
import UIKit
import ImageIO
import os.log

/// Playback loop behavior for the current audiobook.
enum LoopMode: String, Codable {
    /// No looping; playback advances normally.
    case off
    /// Loop the current chapter repeatedly.
    case chapter
    /// Loop between consecutive bookmarks.
    case bookmark
}

// MARK: - Sleep Timer Mode

/// Controls when playback should automatically pause.
enum SleepTimerMode: Equatable {
    /// No sleep timer is active.
    case off
    /// Pause after the given number of minutes elapses.
    case minutes(Int)
    /// Pause when the current chapter ends.
    case endOfChapter

    /// Whether a sleep timer is currently armed.
    var isActive: Bool {
        if case .off = self { return false }
        return true
    }
}

// MARK: - Model

/// The central observable model managing audiobook playback, bookmarks,
/// chapter navigation, sleep timer, Watch connectivity, and Now Playing
/// metadata. Serves as the single source of truth for the player UI.
@Observable
final class PlayerModel {
    // MARK: - Services

    let playbackController = PlaybackController()
    let watchSyncManager = WatchSyncManager()

    var audioEngine: AudioEngine { playbackController.audioEngine }
    @ObservationIgnored private weak var settingsManager: SettingsManager?

    /// Convenience accessor for the shared playback state owned by PlaybackController.
    private var state: PlaybackState { playbackController.state }

    // MARK: - Services (continued)

    @ObservationIgnored let playlistManager: PlaylistManager
    let transcriptService: TranscriptService

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
        get { playbackController.isVolumeBoostEnabled }
        set { playbackController.isVolumeBoostEnabled = newValue }
    }

    // MARK: - Sleep timer state (pass-through to SleepTimerManager)

    var sleepTimerMode: SleepTimerMode { sleepTimerManager.mode }
    var sleepTimerRemainingSeconds: Int { sleepTimerManager.remainingSeconds }

    // MARK: - Playlist state (pass-through to PlaybackState)

    var folderURL: URL? { state.folderURL }
    var tracks: [Track] {
        get { state.tracks }
        set { state.tracks = newValue }
    }
    var currentIndex: Int { state.currentIndex }

    // MARK: - Playback state (pass-through to PlaybackState)

    var isPlaying: Bool { state.isPlaying }
    var currentTitle: String { state.currentTitle }
    var currentSubtitle: String { state.currentSubtitle }

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
    @ObservationIgnored private var baseWatchThumbnailData: Data? = nil
    @ObservationIgnored private var currentDisplayArtworkKey: String?
    @ObservationIgnored private var bookmarkArtworkCache: [String: (image: UIImage, watchData: Data?)] = [:]

    // MARK: - Chapters (pass-through to PlaybackState)

    var chapters: [Chapter] {
        get { state.chapters }
        set { state.chapters = newValue }
    }
    var transcription: [TranscriptionSegment] {
        get { state.transcription }
        set { state.transcription = newValue }
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

    var deepLinkHandler = DeepLinkHandler()
    let nowPlayingController = NowPlayingController()
    let bookmarkStore = BookmarkStore()
    let sleepTimerManager = SleepTimerManager()

    private func loadTranscript(for url: URL) {
        transcriptService.loadTranscript(for: url)
    }

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

    /// UUID of the most recently triggered bookmark, used to prevent retrigger loops.
    @ObservationIgnored private var lastTriggeredBookmarkID: UUID?
    /// Player time at which the most recent bookmark was triggered, used to suppress duplicate firings.
    @ObservationIgnored private var lastTriggeredAtPlayerSecond: Double = -1
    /// The player time used during the last bookmark voice-memo trigger check.
    @ObservationIgnored private var lastBookmarkCheckSecond: Double?

    /// Tracks the last track ID for which a thumbnail was sent to the watch,
    /// avoiding redundant heavy image transfers on every periodic sync.

    /// The display scale used for thumbnail rendering. Set from the SwiftUI
    /// environment to avoid `UIScreen.main` deprecation on iOS 26+.
    private var displayScale: CGFloat = 2.0

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

    // MARK: - Security-scoped access (delegated to SecurityScopeManager)

    let persistence = Persistence()
    let securityScope = SecurityScopeManager()

    /// Current app-level output gain in dB, used for watch crown volume control.
    /// Not observable — gain changes don't trigger view re-renders.
    @ObservationIgnored private var _outputGain: Float = 0

    /// Optional database service for SQL persistence.
    /// Set externally to enable SQL-backed bookmark storage.
    var databaseService: DatabaseService?

    init() {
        SettingsManager.registerDefaults()

        playlistManager = PlaylistManager(state: playbackController.state, persistence: persistence)
        transcriptService = TranscriptService(state: playbackController.state)
        playbackController.delegate = self

        watchSyncManager.onMessage = { [weak self] message, reply in
            self?.handleMessage(message, replyHandler: reply)
        }
        watchSyncManager.onReceiveApplicationContext = { [weak self] context in
            self?.handleMessage(context)
        }
        watchSyncManager.onReceiveFile = { [weak self] file in
            self?.handleWatchBookmarkFile(file)
        }
        watchSyncManager.stateProvider = { [weak self] in
            self?.watchStateContext() ?? [:]
        }
        watchSyncManager.thumbnailProvider = { [weak self] in
            guard let self, self.state.tracks.indices.contains(self.currentIndex) else {
                return (nil, nil)
            }
            return (self.currentArtworkSyncKey, self.watchThumbnailData)
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
            bookmarkArtworkCache.removeAll()
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
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

        sleepTimerManager.onFire = { [weak self] in
            guard let self else { return }
            if self.isPlaying { self.pause() }
            self.syncToWatch()
        }
        sleepTimerManager.onTick = { [weak self] in
            self?.syncToWatch()
        }

        // Wire PlaybackController coordination closures.
        playbackController.coordinator_smartRewind = { [weak self] pausedDuration in
            self?.smartRewindAmount(for: pausedDuration) ?? 0
        }
        playbackController.coordinator_jumpToChapterStartForHours = { [weak self] pausedDuration in
            self?.shouldJumpToChapterStartForHoursLevel(pausedDuration: pausedDuration) ?? false
        }
        playbackController.coordinator_loadTrack = { [weak self] index, autoplay in
            self?.prepareToPlay(index: index, autoplay: autoplay)
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
            self?.updateCurrentDisplayArtwork(at: at, force: force)
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
        playlistManager.coordinator_postResetRefresh = { [weak self] in
            self?.updateCurrentChapterFromPlayerTime()
        }
    }

    private func handleMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        DispatchQueue.main.async {
            var commandResult: String?
            if let command = message["command"] as? String {
                switch command {
                case "play": self.play()
                case "pause": self.pause()
                case "next":
                    if self.skipForwardNavigation() { commandResult = "bookmarkJump" }
                case "previous":
                    if self.skipBackwardNavigation() { commandResult = "bookmarkJump" }
                case "skipBackward":
                    if self.skipBackward30() { commandResult = "bookmarkJump" }
                case "skipForward":
                    if self.skipForward30() { commandResult = "bookmarkJump" }
                case "seek":
                    if let fraction = message["fraction"] as? Double {
                        self.seek(toFraction: fraction)
                    }
                case "scrubDelta":
                    if let d = message["delta"] as? Double {
                        let sens = self.settingsManager?.crownScrubSensitivity ?? SettingsManager.Defaults.crownScrubSensitivity
                        let mult = sens > 0 ? sens : SettingsManager.Defaults.crownScrubSensitivity
                        let current = self.audioEngine.currentTime
                        let duration = self.durationSeconds ?? 0
                        let target = max(0, min(duration, current + (d * 30.0 * mult)))
                        self.seek(toSeconds: target)
                    }
                case "volumeDelta":
                    if let d = message["delta"] as? Double {
                        let sens = self.settingsManager?.crownVolumeSensitivity ?? SettingsManager.Defaults.crownVolumeSensitivity
                        let mult = sens > 0 ? sens : SettingsManager.Defaults.crownVolumeSensitivity
                        let newGain = max(-40, min(9, self._outputGain + Float(d * 6 * mult)))
                        self._outputGain = newGain
                        self.audioEngine.setGain(newGain)
                    }
                case "toggle": self.togglePlayPause()
                case "toggleLoopMode", "cycleLoopMode":
                    self.cycleLoopMode()
                case "cycleSpeed":
                    if let newSpeed = message["playbackSpeed"] as? Double {
                        self.setSpeed(Float(newSpeed))
                    } else {
                        let speeds: [Float] = [1.0, 1.25, 1.5, 2.0]
                        let idx = speeds.firstIndex(of: self.speed) ?? -1
                        let next = speeds[(idx + 1) % speeds.count]
                        self.setSpeed(next)
                    }
                case "setSleepTimer":
                    if let modeStr = message["sleepTimerMode"] as? String {
                        switch modeStr {
                        case "off":
                            self.setSleepTimer(.off)
                        case "endOfChapter":
                            self.setSleepTimer(.endOfChapter)
                        case "minutes":
                            let mins = (message["sleepTimerMinutes"] as? Int) ?? 15
                            self.setSleepTimer(.minutes(mins))
                        default: break
                        }
                    }
                case "cancelSleepTimer":
                    self.cancelSleepTimer()
                case "addBookmark":
                    _ = self.addBookmarkAtCurrentTime()
                case "addWatchTextBookmark":
                    self.addWatchBookmark(from: message)
                case "addWatchVoiceBookmark":
                    self.addWatchVoiceBookmark(from: message)
                case "requestState":
                    break
                default: break
                }
            }
            var reply = self.watchStateContext()
            if let thumbnailData = self.watchThumbnailData {
                reply["thumbnailData"] = thumbnailData
            }
            if let commandResult {
                reply["commandResult"] = commandResult
            }
            replyHandler?(reply)
        }
    }
    
    /// Delegates to `WatchSyncManager.syncToWatch()`.
    func syncToWatch() {
        watchSyncManager.syncToWatch()
    }

    private var currentArtworkSyncKey: String? {
        guard state.tracks.indices.contains(currentIndex) else { return nil }
        let trackId = state.tracks[currentIndex].id
        return "\(trackId)#\(currentDisplayArtworkKey ?? "base")"
    }

    private func watchStateContext() -> [String: Any] {
        var context: [String: Any] = [:]
        context["isPlaying"] = isPlaying
        context["progressFraction"] = progressFraction
        context["currentTime"] = currentPlaybackTime
        context["bookmarkStorageKey"] = bookmarksStorageKey
        context["folderKey"] = folderURL?.absoluteString
        if state.tracks.indices.contains(currentIndex) {
            context["trackId"] = state.tracks[currentIndex].id
        }
        
        let title = state.chapters.count >= 2 ? (currentSubtitle.isEmpty ? String(localized: "Chapter \((currentChapterIndex ?? 0) + 1)") : currentSubtitle) : currentTitle
        context["title"] = title
        
        // Dual-progress: total book progress (time-based when possible)
        // For single-file M4B, currentTime is the absolute file position and
        // durationSeconds is the full file duration — dividing yields true
        // time-based book progress instead of a chapter-count approximation.
        if let duration = durationSeconds, duration.isFinite, duration > 0 {
            let totalElapsed = currentPlaybackTime
            context["totalProgressFraction"] = min(1, max(0, totalElapsed / duration))
            context["totalBookDuration"] = duration
        } else {
            // Fallback: track-count-based for multi-file playlists where
            // individual track durations aren't aggregated.
            let totalCount = Double(state.tracks.count)
            context["totalProgressFraction"] = totalCount > 0 ? (Double(currentIndex) + progressFraction) / totalCount : 0.0
        }
        
        let settings = settingsManager
        let crownAction = settings?.crownAction ?? SettingsManager.Defaults.crownAction
        context["crownAction"] = crownAction
        context["isHapticFeedbackEnabled"] = settings?.isHapticFeedbackEnabled ?? SettingsManager.Defaults.isHapticFeedbackEnabled
        context["watchQuickBookmarkTimeoutSeconds"] = settings?.watchQuickBookmarkTimeoutSeconds ?? SettingsManager.Defaults.watchQuickBookmarkTimeoutSeconds
        context["loopMode"] = loopMode.rawValue
        context["playbackSpeed"] = Double(speed)
        
        context["watchPage1"] = (try? JSONEncoder().encode(settings?.watchPage1 ?? SettingsManager.Defaults.watchPage1)) ?? Data()
        context["watchPage2"] = (try? JSONEncoder().encode(settings?.watchPage2 ?? SettingsManager.Defaults.watchPage2)) ?? Data()
        context["linearBarMode"] = settings?.linearBarMode ?? SettingsManager.Defaults.linearBarMode
        context["linearBarHidden"] = settings?.linearBarHidden ?? SettingsManager.Defaults.linearBarHidden
        context["circularRingMode"] = settings?.circularRingMode ?? SettingsManager.Defaults.circularRingMode
        context["circularRingHidden"] = settings?.circularRingHidden ?? SettingsManager.Defaults.circularRingHidden
        context["watchArtworkLayout"] = settings?.watchArtworkLayout ?? SettingsManager.Defaults.watchArtworkLayout
        context["watchBackgroundStyle"] = settings?.watchBackgroundStyle ?? SettingsManager.Defaults.watchBackgroundStyle
        context["hasThumbnail"] = watchThumbnailData != nil

        // Sleep timer state for watch UI.
        switch sleepTimerMode {
        case .off:
            context["sleepTimerMode"] = "off"
            context["sleepTimerRemainingSeconds"] = 0
        case .minutes(let mins):
            context["sleepTimerMode"] = "minutes"
            context["sleepTimerMinutes"] = mins
            context["sleepTimerRemainingSeconds"] = sleepTimerRemainingSeconds
        case .endOfChapter:
            context["sleepTimerMode"] = "endOfChapter"
            context["sleepTimerRemainingSeconds"] = 0
        }

        // Word cloud data: top 10 words for the current chapter.
        let cloud = currentChapterWordCloud.prefix(10)
        if !cloud.isEmpty, let jsonData = try? JSONEncoder().encode(Array(cloud)),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            context["wordCloudJSON"] = jsonString
            context["wordCloudChapterIndex"] = currentChapterIndex ?? 0
        }

        return context
    }

    private func handleWatchBookmarkFile(_ file: WCSessionFile) {
        guard let command = file.metadata?["command"] as? String, command == "addWatchVoiceBookmark" else {
            return
        }

        let fileName = (file.metadata?["voiceMemoFileName"] as? String) ?? file.fileURL.lastPathComponent
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        let destinationURL = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(safeFileName)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: destinationURL)
        } catch {
            print("Watch voice bookmark copy failed: \(error)")
            return
        }

        var metadata = file.metadata ?? [:]
        metadata["voiceMemoFileName"] = safeFileName

        DispatchQueue.main.async {
            self.addWatchBookmark(from: metadata)
        }
    }

    private func addWatchVoiceBookmark(from payload: [String: Any]) {
        guard let voiceMemoData = payload["voiceMemoData"] as? Data else {
            return
        }

        let fileName = (payload["voiceMemoFileName"] as? String) ?? "watch-memo-\(UUID().uuidString).m4a"
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        let destinationURL = Bookmark.legacyVoiceMemoDirectory().appendingPathComponent(safeFileName)
        var metadata = payload
        metadata["voiceMemoFileName"] = safeFileName
        metadata.removeValue(forKey: "voiceMemoData")

        Task.detached(priority: .utility) {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try voiceMemoData.write(to: destinationURL, options: .atomic)
            } catch {
                print("Watch voice bookmark write failed: \(error)")
                return
            }

            await MainActor.run {
                self.addWatchBookmark(from: metadata)
            }
        }
    }

    deinit {
        
        
        audioEngine.cleanup()
        bookmarkStore.stopVoiceMemo()
        endBackgroundTask()
        stopAllSecurityScope()
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
        stop()

        state.folderURL = url
        
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        
        if isDir.boolValue {
            tracks = playlistManager.loadTracks(from: url)
        } else {
            tracks = [Track(url: url, title: url.deletingPathExtension().lastPathComponent)]
        }
        
        if let folderKey = folderURL?.absoluteString,
           let savedTrackId = persistence.getLastTrack(for: folderKey),
           let idx = state.tracks.firstIndex(where: { $0.id == savedTrackId }) {
            state.currentIndex = idx
        } else {
            state.currentIndex = 0
        }

        if state.tracks.indices.contains(currentIndex) {
            state.currentTitle = state.tracks[currentIndex].title
            prepareToPlay(index: currentIndex, autoplay: autoplay)
            applyPendingDeepLinkSeekIfPossible()
        } else {
            state.currentTitle = String(localized: "No .mp3/.m4a/.m4b files found")
            updateNowPlayingInfo(isPaused: true) // keep something stable in Now Playing
        }

        persistSelection(url: url)

        // Route bookmark persistence through SQL when available.
        if let db = databaseService {
            bookmarkStore.configureSQLPersistence(database: db)
        }
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
        playbackController.pause()
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

    private func applyPendingDeepLinkSeekIfPossible() {
        guard let action = deepLinkHandler.applyPendingSeekIfPossible(isItemLoaded: audioEngine.isItemLoaded) else { return }
        if case .seek(let time) = action {
            seek(toSeconds: time)
        }
    }

    func setSpeed(_ newSpeed: Float) {
        playbackController.setSpeed(newSpeed)
    }

    func setVolumeBoost(enabled: Bool) {
        playbackController.setVolumeBoost(enabled: enabled)
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

    private func stop() {
        playbackController.stop()
    }

    private func prepareToPlay(index: Int, autoplay: Bool) {
        guard state.tracks.indices.contains(index) else { return }

        // Save progress before changing track
        if let folder = folderURL?.absoluteString, state.tracks.indices.contains(currentIndex) {
            persistence.saveBookProgress(for: folder, trackId: state.tracks[currentIndex].id, time: audioEngine.currentTime)
        }

        state.currentIndex = index
        state.currentTitle = tracks[index].title
        state.currentSubtitle = ""
        state.thumbnailImage = nil
        state.currentDisplayArtwork = nil
        state.watchThumbnailData = nil
        baseWatchThumbnailData = nil
        currentDisplayArtworkKey = nil
        bookmarkArtworkCache.removeAll()

        loadTranscript(for: tracks[index].url)

        if let folderURL = folderURL {
            persistence.saveLastTrack(for: folderURL.absoluteString, trackId: tracks[index].id)
        }

        // Load the specific speed for this book
        if let key = folderURL?.absoluteString {
            speed = persistence.getSpeed(for: key) ?? 1.25
            if let raw = persistence.getLoopMode(for: key), let mode = LoopMode(rawValue: raw) {
                loopMode = mode
            } else {
                loopMode = .off
            }
        } else {
            speed = 1.25
            loopMode = .off
        }
        audioEngine.setSpeed(speed)
        state.chapters = []
        state.currentChapterIndex = nil
        state.isSeekingForChapterBoundary = false
        state.isManualSeeking = false
        lastBookmarkCheckSecond = nil

        
        

        // For Files/iCloud-provider URLs:
        startSelectionSecurityScopeIfNeeded()
        stopCurrentFileSecurityScopeIfNeeded()
        startCurrentFileSecurityScopeForURL(tracks[index].url)

        let trackURL = tracks[index].url
        Task {
            await ArtworkCache.ensureItemIsAvailable(url: trackURL)
        }

        // AudioEngine handles AVPlayerItem creation, observers, and duration loading.
        configureAudioSessionIfNeeded()
        audioEngine.replaceCurrentItem(with: trackURL)

        playbackController.applySpeedToCurrentItem()
        configureRemoteCommandsIfNeeded()

        // Prime Now Playing metadata even before play (helps show stable controls)
        updateNowPlayingInfo(isPaused: true)
        updateProgressFromPlayer()
        syncToWatch()

        Task { [weak self] in
            guard let self else { return }
            await self.loadChaptersForCurrentItem()
            await self.loadDurationForNowPlaying()
            await self.generateThumbnail(for: trackURL)

            await MainActor.run {
                if autoplay {
                    self.play()
                }
            }
        }
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
            skipBackward: { [weak self] in self?.skipBackward30() }
        )
    }

    private func updateNowPlayingElapsedTime() {
        guard audioEngine.isItemLoaded else { return }
        let current = audioEngine.currentTime
        guard current.isFinite else { return }

        let chapterOffset: TimeInterval?
        if state.chapters.count >= 2, let idx = currentChapterIndex {
            chapterOffset = chapters[idx].startSeconds
        } else {
            chapterOffset = nil
        }

        nowPlayingController.updateElapsedTime(current, chapterStartOffset: chapterOffset)
    }

    private func updateNowPlayingInfo(isPaused: Bool) {
        let elapsed = audioEngine.currentTime

        var params = NowPlayingController.NowPlayingParams()
        params.title = currentTitle
        params.subtitle = currentSubtitle
        params.elapsed = elapsed
        params.isPaused = isPaused
        params.playbackRate = speed
        params.artworkImage = currentDisplayArtwork ?? thumbnailImage
        params.duration = durationSeconds ?? 0

        if state.chapters.count >= 2, let idx = currentChapterIndex {
            let c = chapters[idx]
            params.chapterIndex = idx
            params.chapterElapsed = max(0, elapsed - c.startSeconds)
            params.chapterDuration = c.endSeconds - c.startSeconds
        } else {
            params.albumTitle = currentSubtitle.isEmpty ? nil : currentSubtitle
        }

        nowPlayingController.updateNowPlayingInfo(params)
    }

    private func updateProgressFromPlayer() {
        guard audioEngine.isItemLoaded else {
            state.progressFraction = 0
            state.progressText = "--:--"
            state.elapsedText = "--:--"
            return
        }

        let elapsed = audioEngine.currentTime

        if state.chapters.count >= 2 {
            if let idx = currentChapterIndex {
                let c = chapters[idx]
                if elapsed.isFinite, elapsed < c.startSeconds - 0.1 || elapsed >= c.endSeconds + 0.1 {
                    updateCurrentChapterFromPlayerTime()
                }
            } else {
                updateCurrentChapterFromPlayerTime()
            }

            if let idx = currentChapterIndex {
                let c = chapters[idx]
                let chapterDuration = c.endSeconds - c.startSeconds
                let chapterElapsed = elapsed - c.startSeconds

                if chapterElapsed.isFinite, chapterDuration.isFinite, chapterDuration > 0 {
                    let frac = min(1, max(0, chapterElapsed / chapterDuration))
                    let didChange = abs(progressFraction - frac) > 0.005
                    state.progressFraction = frac
                    let remaining = max(0, chapterDuration - chapterElapsed) / Double(speed)
                    state.progressText = "-\(NowPlayingController.formatTime(remaining))"
                    state.elapsedText = NowPlayingController.formatTime(max(0, chapterElapsed) / Double(speed))
                    if didChange { syncToWatch() }
                    return
                }
            }
        }

        let duration = durationSeconds ?? 0

        guard elapsed.isFinite, duration.isFinite, duration > 0 else {
            state.progressFraction = 0
            state.progressText = "--:--"
            state.elapsedText = "--:--"
            return
        }

        let frac = min(1, max(0, elapsed / duration))
        let didChange = abs(progressFraction - frac) > 0.005
        state.progressFraction = frac

        let remaining = max(0, duration - elapsed) / Double(speed)
        state.progressText = "-\(NowPlayingController.formatTime(remaining))"
        state.elapsedText = NowPlayingController.formatTime(max(0, elapsed) / Double(speed))
        if didChange { syncToWatch() }
    }


    private func loadDurationForNowPlaying() async {
        guard let seconds = audioEngine.duration, seconds > 0 else { return }
        state.durationSeconds = seconds
        updateNowPlayingInfo(isPaused: !isPlaying)
        updateProgressFromPlayer()

        // Once asset is ready, check for saved progress and seek
        if deepLinkHandler.pendingSeekTime != nil {
            await MainActor.run {
                self.applyPendingDeepLinkSeekIfPossible()
            }
        } else if let folder = folderURL?.absoluteString,
           let progress = persistence.getBookProgress(for: folder),
           state.tracks.indices.contains(currentIndex),
           progress.trackId == state.tracks[currentIndex].id,
           progress.time > 0, progress.time < seconds {
            let savedTime = progress.time
            await MainActor.run {
                state.isManualSeeking = true
                audioEngine.seek(to: savedTime) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.state.isManualSeeking = false
                                self?.updateCurrentChapterFromPlayerTime()
                                self?.updateNowPlayingElapsedTime()
                                self?.updateProgressFromPlayer()
                                if let self, self.isPlaying {
                                    self.audioEngine.playImmediately(atRate: self.speed)
                                    self.playbackController.applySpeedToCurrentItem()
                                }
                            }
                        }
                    }
                }
            }

    private func generateThumbnail(for url: URL) async {
        let sourceImage: UIImage?
        if let embedded = await ArtworkCache.embeddedArtworkImage(for: url) {
            sourceImage = embedded
        } else if let folderImage = await ArtworkCache.folderArtworkImage(near: url) {
            sourceImage = folderImage
        } else {
            sourceImage = loadAppIconImage()
        }

        guard let sourceImage else {
            await MainActor.run {
                state.thumbnailImage = nil
                state.currentDisplayArtwork = nil
                state.watchThumbnailData = nil
                baseWatchThumbnailData = nil
                currentDisplayArtworkKey = nil
                updateNowPlayingInfo(isPaused: !isPlaying)
                syncToWatch()
            }
            return
        }

        let scale = displayScale
        let result = await Task.detached(priority: .userInitiated) {
            ArtworkCache.generateThumbnails(from: sourceImage, displayScale: scale)
        }.value

        await MainActor.run {
            state.thumbnailImage = result.0
            baseWatchThumbnailData = result.1
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
        }
    }

    private func loadChaptersForCurrentItem() async {
        guard audioEngine.isItemLoaded,
              state.tracks.indices.contains(currentIndex) else { return }
        let asset = AVURLAsset(url: state.tracks[currentIndex].url)

        let ext = state.tracks[currentIndex].url.pathExtension.lowercased()
        guard ext == "m4b" || ext == "m4a" else { return }

        var built = await ChapterService.parseChapters(from: asset)

        let trackKey = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].url.absoluteString : ""
        if let savedStates = persistence.loadEnabledState(for: trackKey) {
            for i in 0..<built.count {
                if let isEnabled = savedStates[built[i].id] {
                    built[i].isEnabled = isEnabled
                }
            }
        }
        if let savedOrder = persistence.loadOrder(for: trackKey) {
            var orderedChapters: [Chapter] = []
            var remainingChapters = built
            for id in savedOrder {
                if let idx = remainingChapters.firstIndex(where: { $0.id == id }) {
                    orderedChapters.append(remainingChapters.remove(at: idx))
                }
            }
            orderedChapters.append(contentsOf: remainingChapters)
            built = orderedChapters
        }

        // Some files return a single "chapter" spanning whole book; treat that as "no chapters".
        if built.count >= 2 {
            chapters = built
            updateCurrentChapterFromPlayerTime()
            
        } else {
            state.chapters = []
            state.currentChapterIndex = nil
            state.currentSubtitle = ""
            
            updateNowPlayingInfo(isPaused: !isPlaying)
            syncToWatch()
        }
        computeWordClouds()
    }

    private func updateCurrentChapterFromPlayerTime() {
        guard state.chapters.count >= 2, audioEngine.isItemLoaded else { return }
        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        // Find all chapters that contain the current time
        let matching = chapters.filter { t >= $0.startSeconds && t < $0.endSeconds }
        
        // Pick the most specific one (shortest duration) to ignore global/overlapping chapters
        if let bestMatch = matching.min(by: { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) }),
           let idx = state.chapters.firstIndex(of: bestMatch) {
            
            if currentChapterIndex != idx {
                state.currentChapterIndex = idx
                let c = state.chapters[idx]
                if let title = c.title, !title.isEmpty {
                    state.currentSubtitle = title
                } else {
                    state.currentSubtitle = String(localized: "Chapter \(idx + 1)")
                }
                updateNowPlayingInfo(isPaused: !isPlaying)
                syncToWatch()
            }
        }
    }

    // MARK: - Bookmarks API

    /// The persistence key for the currently loaded book, derived from the folder
    /// URL or the current track ID. Used to scope bookmark and progress storage.
    private var bookmarksStorageKey: String? {
        if let f = folderURL?.absoluteString { return f }
        if state.tracks.indices.contains(currentIndex) { return state.tracks[currentIndex].id }
        return nil
    }

    /// Loads bookmarks from persistent storage for the currently loaded book.
    /// Falls back to an empty list if no storage key is available.
    func loadBookmarksForCurrentBook() {
        guard let key = bookmarksStorageKey else {
            bookmarkStore.bookmarks = []
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
            return
        }
        bookmarkStore.bookmarks = persistence.loadBookmarks(for: key, folderURL: folderURL).sorted { $0.timestamp < $1.timestamp }
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
    }

    /// Bookmarks scoped to the currently playing track, sorted by timestamp.
    var currentTrackBookmarks: [Bookmark] {
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        return bookmarkStore.trackBookmarks(for: trackId)
    }

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

    private func updateCurrentDisplayArtwork(at currentTime: TimeInterval, force: Bool = false) {
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        let activeBookmark = Self.activeArtworkBookmark(from: bookmarks, at: currentTime, trackId: trackId)
        let nextKey = activeBookmark.flatMap { bookmark -> String? in
            guard let fileName = bookmark.bookmarkImageFileName else { return nil }
            return "bookmark:\(bookmark.id.uuidString):\(fileName)"
        } ?? "base"

        guard force || nextKey != currentDisplayArtworkKey else { return }
        currentDisplayArtworkKey = nextKey

        if let activeBookmark,
           let fileName = activeBookmark.bookmarkImageFileName,
           let imageURL = activeBookmark.bookmarkImageURL(in: folderURL) {
            let cacheKey = imageURL.path
            if let cached = bookmarkArtworkCache[cacheKey] {
                state.currentDisplayArtwork = cached.image
                state.watchThumbnailData = cached.watchData
            } else if let image = UIImage(contentsOfFile: imageURL.path) {
                let watchData = makeWatchThumbnailData(from: image)
                bookmarkArtworkCache[cacheKey] = (image, watchData)
                state.currentDisplayArtwork = image
                state.watchThumbnailData = watchData
            } else {
                print("Failed to load bookmark artwork: \(fileName)")
                state.currentDisplayArtwork = thumbnailImage
                state.watchThumbnailData = baseWatchThumbnailData
            }
        } else {
            state.currentDisplayArtwork = thumbnailImage
            state.watchThumbnailData = baseWatchThumbnailData
        }

        updateNowPlayingInfo(isPaused: !isPlaying)
        syncToWatch()
        state.currentDisplayArtworkVersion += 1
    }

    private func makeWatchThumbnailData(from image: UIImage) -> Data? {
        ArtworkCache.makeWatchThumbnailData(from: image)
    }

    /// Creates a new bookmark at the current playback position with an
    /// auto-numbered title. Persists the bookmark list immediately.
    /// - Returns: The newly created bookmark, or `nil` if playback is unavailable.
    @discardableResult
    func addBookmarkAtCurrentTime() -> Bookmark? {
        guard audioEngine.isItemLoaded else { return nil }
        let t = audioEngine.currentTime
        guard t.isFinite else { return nil }
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        return bookmarkStore.addBookmark(at: t, trackId: trackId, folderKey: folderURL?.absoluteString)
    }

    /// Creates a draft bookmark at the current playback position without
    /// persisting it. Useful for presenting a pre-filled editor before saving.
    /// - Returns: A draft bookmark, or `nil` if playback is unavailable.
    func bookmarkDraftAtCurrentTime() -> BookmarkDraft? {
        guard audioEngine.isItemLoaded else { return nil }
        let t = audioEngine.currentTime
        guard t.isFinite else { return nil }
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        return bookmarkStore.bookmarkDraft(at: t, trackId: trackId, folderKey: folderURL?.absoluteString)
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
        bookmarkStore.appendBookmark(
            from: draft, title: title, timestamp: timestamp, note: note,
            voiceMemoFileName: voiceMemoFileName, bookmarkImageFileName: bookmarkImageFileName
        )
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
        bookmarkArtworkCache.removeAll()
        bookmarkStore.updateBookmark(
            id: id, title: title, timestamp: timestamp, note: note,
            voiceMemoFileName: voiceMemoFileName, bookmarkImageFileName: bookmarkImageFileName
        )
    }

    private func addWatchBookmark(from payload: [String: Any]) {
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
        var targetBookmarks = isCurrentBook
            ? bookmarkStore.bookmarks
            : persistence.loadBookmarks(for: storageKey, folderURL: targetFolderURL)
        let scopedCount = targetBookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count

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

    /// Jumps playback to a bookmark's timestamp, suppressing the voice-memo
    /// overlay trigger to avoid unwanted playback interruption.
    func jumpToBookmark(_ bm: Bookmark) {
        // Suppress retrigger when the user manually navigates to a bookmark.
        lastTriggeredBookmarkID = bm.id
        lastTriggeredAtPlayerSecond = bm.timestamp
        seek(toSeconds: bm.timestamp)
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
    private func checkVoiceMemoTrigger(at currentSeconds: Double, previousSeconds: Double?) {
        let trackId = state.tracks.indices.contains(currentIndex) ? state.tracks[currentIndex].id : nil
        if let memoURL = bookmarkStore.checkVoiceMemoTrigger(
            at: currentSeconds,
            previousSeconds: previousSeconds,
            isPlaying: isPlaying,
            isManualSeeking: state.isManualSeeking,
            loopMode: loopMode,
            playBookmarksInline: settingsManager?.playBookmarksInline ?? SettingsManager.Defaults.playBookmarksInline,
            trackId: trackId,
            folderURL: folderURL,
            lastTriggeredBookmarkID: &lastTriggeredBookmarkID,
            lastTriggeredAtPlayerSecond: &lastTriggeredAtPlayerSecond
        ) {
            bookmarkStore.startVoiceMemoPlayback(url: memoURL)
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


// MARK: - PlaybackControllerDelegate

extension PlayerModel: PlaybackControllerDelegate {
    func playbackController(_ controller: PlaybackController, didUpdateTime currentTime: TimeInterval) {
        autoreleasepool {
            updateNowPlayingElapsedTime()
            updateCurrentChapterFromPlayerTime()
            updateProgressFromPlayer()
            updateCurrentDisplayArtwork(at: currentTime)
            playbackController.enforceEnabledState()
            playbackController.applyChapterLoopIfNeeded()
            playbackController.applyBookmarkLoopIfNeeded()
            if settingsManager?.playBookmarksInline ?? SettingsManager.Defaults.playBookmarksInline,
               currentTime.isFinite {
                checkVoiceMemoTrigger(at: currentTime, previousSeconds: lastBookmarkCheckSecond)
                lastBookmarkCheckSecond = currentTime
            }
        }
    }

    func playbackControllerDidPlayToEnd(_ controller: PlaybackController) {
        playbackController.handleTrackEnded()
    }

    func playbackControllerInterruptionBegan(_ controller: PlaybackController) {
        pause()
    }

    func playbackControllerInterruptionEnded(_ controller: PlaybackController, shouldResume: Bool) {
        if shouldResume {
            play()
        }
    }
}
