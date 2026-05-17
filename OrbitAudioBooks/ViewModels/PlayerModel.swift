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

    /// Temporary bridge — allows existing callers to access the audio engine
    /// through `audioEngine` while methods are gradually moved to PlaybackController.
    var audioEngine: AudioEngine { playbackController.audioEngine }
    @ObservationIgnored private weak var settingsManager: SettingsManager?

    // MARK: - UI state

    /// The current playback loop mode (off, chapter, or bookmark).
    var loopMode: LoopMode {
        get { playbackController.loopMode }
        set { playbackController.loopMode = newValue }
    }
    /// Playback speed multiplier. Persisted per-book.
    var speed: Float {
        get { playbackController.speed }
        set { playbackController.speed = newValue }
    }
    /// Whether volume boost (+9 dB) is active.
    var isVolumeBoostEnabled: Bool {
        get { playbackController.isVolumeBoostEnabled }
        set { playbackController.isVolumeBoostEnabled = newValue }
    }

    // MARK: - Sleep timer state

    /// The currently armed sleep-timer mode.
    var sleepTimerMode: SleepTimerMode { sleepTimerManager.mode }
    /// Remaining seconds for time-based sleep timer modes.
    var sleepTimerRemainingSeconds: Int { sleepTimerManager.remainingSeconds }

    // MARK: - Playlist state

    /// The folder or single file currently loaded as the active playlist.
    private(set) var folderURL: URL?
    /// The ordered list of audio tracks in the current playlist.
    var tracks: [Track] = []
    /// The index into `tracks` of the currently loaded item.
    private(set) var currentIndex: Int = 0

    // MARK: - Playback state

    /// Whether the player is currently playing.
    private(set) var isPlaying: Bool = false
    /// The title of the currently playing track.
    private(set) var currentTitle: String = String(localized: "No track selected")
    /// The subtitle of the currently playing track, typically the chapter name.
    private(set) var currentSubtitle: String = ""

    // MARK: - Progress

    /// Playback progress as a fraction from 0.0 to 1.0, scoped to the current
    /// chapter when chapters are available, or the full track otherwise.
    private(set) var progressFraction: Double = 0.0
    /// Remaining time formatted as a string (e.g. "-12:34").
    private(set) var progressText: String = "--:--"
    /// Elapsed time formatted as a string (e.g. "1:23").
    private(set) var elapsedText: String = "--:--"
    /// The total duration of the current item, in seconds, or `nil` if unknown.
    private(set) var durationSeconds: Double? = nil
    /// Current playback position in seconds. Views should use this instead of
    /// reaching into the underlying AVPlayer.
    var currentPlaybackTime: TimeInterval { audioEngine.currentTime }
    /// The artwork image displayed in Now Playing and the player UI.
    private(set) var thumbnailImage: UIImage? = nil
    /// The artwork currently displayed by the player. Picture bookmarks can
    /// temporarily replace the base audiobook cover.
    private(set) var currentDisplayArtwork: UIImage? = nil
    private(set) var currentDisplayArtworkVersion: Int = 0
    /// A downscaled JPEG representation of the current display artwork for Watch transfer.
    private(set) var watchThumbnailData: Data? = nil
    @ObservationIgnored private var baseWatchThumbnailData: Data? = nil
    @ObservationIgnored private var currentDisplayArtworkKey: String?
    @ObservationIgnored private var bookmarkArtworkCache: [String: (image: UIImage, watchData: Data?)] = [:]

    // MARK: - Chapters

    /// Chapters parsed from the current track's M4B/M4A metadata.
    /// Empty when the track has no chapter markers.
    var chapters: [Chapter] = []
    /// Transcription segments for the current track, loaded from a sidecar JSON.
    var transcription: [TranscriptionSegment] = []
    /// The index of the currently active chapter, or `nil` when chapters are unavailable.
    private(set) var currentChapterIndex: Int? = nil
    /// Per-chapter word frequency maps, computed after transcript and chapters are loaded.
    var chapterWordClouds: [Int: [WordFrequency]] = [:]
    /// Rolling 5-minute window word frequencies for the current track.
    var rollingWordClouds: [(startTime: TimeInterval, frequencies: [WordFrequency])] = []
    /// Word cloud for the currently playing chapter (derived from `currentChapterIndex`).
    var currentChapterWordCloud: [WordFrequency] {
        guard let idx = currentChapterIndex else { return [] }
        return chapterWordClouds[idx] ?? []
    }
    /// Timestamp recorded when playback was last paused, used to calculate
    /// rewind amounts on resume. `nil` while playing.
    private var pauseTimestamp: Date? = nil
    var deepLinkHandler = DeepLinkHandler()
    let nowPlayingController = NowPlayingController()
    let bookmarkStore = BookmarkStore()
    let sleepTimerManager = SleepTimerManager()

    /// Whether the current seek operation was initiated by a chapter boundary jump.
    private var isSeekingForChapterBoundary: Bool = false
    /// Whether the current seek operation was initiated by the user.
    private var isManualSeeking: Bool = false

    /// Loads the transcript sidecar JSON for the given audio file.
    /// The transcript is expected at `<audio>.transcript.json` in the same directory.
    /// - Parameter url: The audio file URL whose sidecar transcript will be loaded.
    private func loadTranscript(for url: URL) {
        let fileName = url.deletingPathExtension().lastPathComponent + ".transcript.json"
        let transcriptURL = url.deletingLastPathComponent().appendingPathComponent(fileName)
        
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            self.transcription = []
            return
        }
        
        do {
            let data = try Data(contentsOf: transcriptURL)
            self.transcription = try JSONDecoder().decode([TranscriptionSegment].self, from: data)
            computeWordClouds()
        } catch {
            print("Failed to load transcript: \(error)")
            self.transcription = []
        }
    }

    /// Computes word frequencies for the full track, per-chapter, and rolling windows.
    /// Called after both transcript and chapter data are available.
    private func computeWordClouds() {
        guard !transcription.isEmpty else { return }

        // Full-track word frequencies.
        let fullFrequencies = WordFrequencyComputer.compute(from: transcription)

        // Per-chapter frequencies.
        if !chapters.isEmpty {
            chapterWordClouds = WordFrequencyComputer.computePerChapter(
                segments: transcription,
                chapters: chapters
            )
        } else {
            // No chapters: store full frequencies under index 0 as the only "chapter."
            chapterWordClouds = [0: fullFrequencies]
        }

        // Rolling 5-minute windows.
        rollingWordClouds = WordFrequencyComputer.computeRollingWindows(
            segments: transcription,
            windowDuration: 300,
            step: 60
        )
    }

    // MARK: - Bookmarks

    /// All bookmarks for the currently loaded book, sorted by timestamp.
    var bookmarks: [Bookmark] = []
    /// Whether a voice memo attached to a bookmark is currently playing in overlay mode.
    private(set) var isPlayingVoiceMemo: Bool = false
    /// 0...1 progress of the currently playing voice memo, for the overlay UI.
    private(set) var voiceMemoProgress: Double = 0.0
    /// The AVAudioEngine used for voice-memo overlay playback.
    @ObservationIgnored private var voiceMemoEngine: AVAudioEngine?
    /// The player node scheduled with the voice-memo audio file.
    @ObservationIgnored private var voiceMemoPlayerNode: AVAudioPlayerNode?
    /// Duration of the currently playing voice memo, in seconds.
    @ObservationIgnored private var voiceMemoDuration: Double = 0
    /// Progress timer fired at 0.1 s intervals during voice-memo playback.
    @ObservationIgnored private var voiceMemoProgressTimer: Timer?

    /// UUID of the most recently triggered bookmark, used to prevent retrigger loops.
    @ObservationIgnored private var lastTriggeredBookmarkID: UUID?
    /// Player time at which the most recent bookmark was triggered, used to suppress duplicate firings.
    @ObservationIgnored private var lastTriggeredAtPlayerSecond: Double = -1
    /// The player time used during the last bookmark voice-memo trigger check.
    @ObservationIgnored private var lastBookmarkCheckSecond: Double?
    /// Per-URL cache of computed voice-memo gain values to avoid recomputation.
    @ObservationIgnored private var voiceMemoGainCache: [String: Float] = [:]

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

    // MARK: - Security-scoped access

    /// Whether the current selection (folder or file) holds a security-scoped resource access grant.
    private var hasSelectionSecurityScopeAccess: Bool = false
    /// The URL for which `hasSelectionSecurityScopeAccess` was obtained.
    private var selectionSecurityScopeURL: URL?
    /// Whether the currently playing file holds a per-file security-scoped resource access grant.
    private var hasCurrentFileSecurityScopeAccess: Bool = false
    /// The URL for which `hasCurrentFileSecurityScopeAccess` was obtained.
    private var currentFileSecurityScopeURL: URL?

    let persistence = Persistence()

    /// Current app-level output gain in dB, used for watch crown volume control.
    /// Not observable — gain changes don't trigger view re-renders.
    @ObservationIgnored private var _outputGain: Float = 0

    init() {
        SettingsManager.registerDefaults()

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
            guard let self, self.tracks.indices.contains(self.currentIndex) else {
                return (nil, nil)
            }
            return (self.currentArtworkSyncKey, self.watchThumbnailData)
        }

        bookmarkStore.onPersist = { [weak self] bookmarks in
            self?.persistBookmarks()
        }
        bookmarkStore.onSwitchToVoiceMemo = { [weak self] in
            self?.switchAudioSource(to: .voiceMemo)
        }
        bookmarkStore.onSwitchToMainPlayer = { [weak self] in
            self?.switchAudioSource(to: .mainPlayer)
        }

        sleepTimerManager.onFire = { [weak self] in
            guard let self else { return }
            if self.isPlaying { self.pause() }
            self.syncToWatch()
        }
        sleepTimerManager.onTick = { [weak self] in
            self?.syncToWatch()
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
        guard tracks.indices.contains(currentIndex) else { return nil }
        let trackId = tracks[currentIndex].id
        return "\(trackId)#\(currentDisplayArtworkKey ?? "base")"
    }

    private func watchStateContext() -> [String: Any] {
        var context: [String: Any] = [:]
        context["isPlaying"] = isPlaying
        context["progressFraction"] = progressFraction
        context["currentTime"] = currentPlaybackTime
        context["bookmarkStorageKey"] = bookmarksStorageKey
        context["folderKey"] = folderURL?.absoluteString
        if tracks.indices.contains(currentIndex) {
            context["trackId"] = tracks[currentIndex].id
        }
        
        let title = chapters.count >= 2 ? (currentSubtitle.isEmpty ? String(localized: "Chapter \((currentChapterIndex ?? 0) + 1)") : currentSubtitle) : currentTitle
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
            let totalCount = Double(tracks.count)
            context["totalProgressFraction"] = totalCount > 0 ? (Double(currentIndex) + progressFraction) / totalCount : 0.0
        }
        
        let settings = settingsManager
        let crownAction = settings?.crownAction ?? SettingsManager.Defaults.crownAction
        context["crownAction"] = crownAction
        context["isHapticFeedbackEnabled"] = settings?.isHapticFeedbackEnabled ?? SettingsManager.Defaults.isHapticFeedbackEnabled
        context["watchQuickBookmarkTimeoutSeconds"] = settings?.watchQuickBookmarkTimeoutSeconds ?? SettingsManager.Defaults.watchQuickBookmarkTimeoutSeconds
        context["loopMode"] = loopMode.rawValue
        context["playbackSpeed"] = Double(speed)
        
        context["watchPage1"] = settings?.watchPage1 ?? SettingsManager.Defaults.watchPage1
        context["watchPage2"] = settings?.watchPage2 ?? SettingsManager.Defaults.watchPage2
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
        voiceMemoProgressTimer?.invalidate()
        voiceMemoPlayerNode?.stop()
        voiceMemoEngine?.stop()
        voiceMemoEngine = nil
        endBackgroundTask()
        stopAllSecurityScope()
    }

    // MARK: Folder + track loading

    /// Reorders tracks within the playlist and persists the new order.
    /// - Parameters:
    ///   - source: The indices of tracks to move.
    ///   - destination: The index to insert the tracks at.
    func moveTracks(from source: IndexSet, to destination: Int) {
        let currentURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil
        tracks.move(fromOffsets: source, toOffset: destination)
        if let currentURL, let newIdx = tracks.firstIndex(where: { $0.url == currentURL }) {
            currentIndex = newIdx
        }
        if let folderURL = folderURL {
            persistence.saveOrder(for: folderURL.absoluteString, ids: tracks.map { $0.id })
        }
    }

    /// Reorders chapters within the current track and persists the new order.
    /// - Parameters:
    ///   - source: The indices of chapters to move.
    ///   - destination: The index to insert the chapters at.
    func moveChapters(from source: IndexSet, to destination: Int) {
        let currentID = (currentChapterIndex != nil && chapters.indices.contains(currentChapterIndex!)) ? chapters[currentChapterIndex!].id : nil
        chapters.move(fromOffsets: source, toOffset: destination)
        if let currentID, let newIdx = chapters.firstIndex(where: { $0.id == currentID }) {
            currentChapterIndex = newIdx
        }
        if let currentTrackURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil {
            persistence.saveOrder(for: currentTrackURL.absoluteString, ids: chapters.map { $0.id })
        }
        
    }

    /// Toggles the enabled state of a track, which determines whether it is
    /// included during sequential playback. Persists the change.
    /// - Parameter index: The index of the track in the `tracks` array.
    func toggleTrackEnabled(at index: Int) {
        tracks[index].isEnabled.toggle()
        if let folderURL = folderURL {
            var states = persistence.loadEnabledState(for: folderURL.absoluteString) ?? [:]
            states[tracks[index].id] = tracks[index].isEnabled
            persistence.saveEnabledState(for: folderURL.absoluteString, states: states)
        }
    }
    
    /// Toggles the enabled state of a chapter, which determines whether it is
    /// included during sequential chapter navigation. Persists the change.
    /// - Parameter index: The index of the chapter in the `chapters` array.
    func toggleChapterEnabled(at index: Int) {
        chapters[index].isEnabled.toggle()
        if let currentTrackURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil {
            var states = persistence.loadEnabledState(for: currentTrackURL.absoluteString) ?? [:]
            states[chapters[index].id] = chapters[index].isEnabled
            persistence.saveEnabledState(for: currentTrackURL.absoluteString, states: states)
        }
        
    }

    /// Resets the playlist to its default order, re-enabling all tracks or
    /// chapters (depending on the content) and persisting the changes.
    func resetPlaylist() {
        if chapters.count >= 2 {
            chapters.sort { $0.startSeconds < $1.startSeconds }
            for i in 0..<chapters.count {
                chapters[i].isEnabled = true
            }
            if let currentTrackURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil {
                persistence.saveOrder(for: currentTrackURL.absoluteString, ids: chapters.map { $0.id })
                var states: [String: Bool] = [:]
                for c in chapters { states[c.id] = true }
                persistence.saveEnabledState(for: currentTrackURL.absoluteString, states: states)
            }
            updateCurrentChapterFromPlayerTime()
            
        } else {
            let currentURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil
            tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for i in 0..<tracks.count {
                tracks[i].isEnabled = true
            }
            if let folderURL = folderURL {
                persistence.saveOrder(for: folderURL.absoluteString, ids: tracks.map { $0.id })
                var states: [String: Bool] = [:]
                for t in tracks { states[t.id] = true }
                persistence.saveEnabledState(for: folderURL.absoluteString, states: states)
            }
            if let currentURL, let newIdx = tracks.firstIndex(where: { $0.url == currentURL }) {
                currentIndex = newIdx
            }
        }
    }

    /// Loads a folder or single audio file as the active playlist. If the URL is a
    /// directory, all supported audio files are enumerated and sorted; if a single
    /// file, it becomes the sole track. Stops any current playback first.
    /// - Parameters:
    ///   - url: The folder or file URL to load.
    ///   - autoplay: Whether to automatically begin playback after loading. Defaults to `true`.
    func loadFolder(_ url: URL, autoplay: Bool = true) {
        stop()

        folderURL = url
        
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        
        if isDir.boolValue {
            tracks = loadTracks(from: url)
        } else {
            tracks = [Track(url: url, title: url.deletingPathExtension().lastPathComponent)]
        }
        
        if let folderKey = folderURL?.absoluteString,
           let savedTrackId = persistence.getLastTrack(for: folderKey),
           let idx = tracks.firstIndex(where: { $0.id == savedTrackId }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }

        if tracks.indices.contains(currentIndex) {
            currentTitle = tracks[currentIndex].title
            prepareToPlay(index: currentIndex, autoplay: autoplay)
            applyPendingDeepLinkSeekIfPossible()
        } else {
            currentTitle = String(localized: "No .mp3/.m4a/.m4b files found")
            updateNowPlayingInfo(isPaused: true) // keep something stable in Now Playing
        }

        persistSelection(url: url)
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

    private func loadTracks(from folder: URL) -> [Track] {
        // Important: for folders from Files app, access can be security-scoped.
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]

        guard let urls = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let allowed = Set(["mp3", "m4a", "m4b"])
        var loadedTracks: [Track] = urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard allowed.contains(ext) else { return nil }
            return Track(url: url, title: url.deletingPathExtension().lastPathComponent)
        }

        loadedTracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        
        let folderKey = folder.absoluteString
        if let savedStates = persistence.loadEnabledState(for: folderKey) {
            for i in 0..<loadedTracks.count {
                if let isEnabled = savedStates[loadedTracks[i].id] {
                    loadedTracks[i].isEnabled = isEnabled
                }
            }
        }
        
        if let savedOrder = persistence.loadOrder(for: folderKey) {
            var orderedTracks: [Track] = []
            var remainingTracks = loadedTracks
            for id in savedOrder {
                if let idx = remainingTracks.firstIndex(where: { $0.id == id }) {
                    orderedTracks.append(remainingTracks.remove(at: idx))
                }
            }
            orderedTracks.append(contentsOf: remainingTracks)
            loadedTracks = orderedTracks
        }

        return loadedTracks
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

    /// Toggles between play and pause states.
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Starts or resumes playback. Applies rewind-on-resume if the feature is
    /// enabled and the player was paused long enough. Re-acquires security-scoped
    /// access and configures the audio session before playing.
    func play() {
        if let pausedAt = pauseTimestamp {
            let pausedDuration = Date().timeIntervalSince(pausedAt)
            if settingsManager?.isRewindEnabled ?? SettingsManager.Defaults.isRewindEnabled {
                if audioEngine.isItemLoaded {
                    let current = audioEngine.currentTime
                    let rewindAmount = smartRewindAmount(for: pausedDuration)
                    var target = current

                    if shouldJumpToChapterStartForHoursLevel(pausedDuration: pausedDuration),
                       chapters.count >= 2,
                       let idx = currentChapterIndex {
                        target = chapters[idx].startSeconds
                    } else if rewindAmount > 0 {
                        target = max(0, current - rewindAmount)
                        
                        // Don't rewind past the start of the current chapter
                        if chapters.count >= 2, let idx = currentChapterIndex {
                            let c = chapters[idx]
                            if target < c.startSeconds {
                                target = c.startSeconds
                            }
                        }
                    }

                    if target != current {
                        isManualSeeking = true
                        audioEngine.seek(to: target) { [weak self] _ in
                            DispatchQueue.main.async {
                                self?.isManualSeeking = false
                                self?.updateCurrentChapterFromPlayerTime()
                            }
                        }
                    }
                }
            }
            pauseTimestamp = nil
        }

        // Release any pause background task claim immediately on resume.
        endBackgroundTask()

        guard !tracks.isEmpty else { return }
        configureAudioSessionIfNeeded()

        if !audioEngine.isItemLoaded { prepareToPlay(index: currentIndex, autoplay: false) }
        startSelectionSecurityScopeIfNeeded()
        startCurrentFileSecurityScopeIfNeeded()

        // Ensure the current item is configured for speech-quality playback before starting.
        applySpeedToCurrentItem()

        audioEngine.playImmediately(atRate: speed)
        isPlaying = true
        let currentSecond = currentPlaybackTime
        if currentSecond.isFinite {
            checkBookmarkVoiceMemoTrigger(at: currentSecond, previousSeconds: nil)
            lastBookmarkCheckSecond = currentSecond
        }

        updateNowPlayingInfo(isPaused: false)
        syncToWatch()
    }

    /// Pauses playback while keeping the audio session active, so Now Playing
    /// metadata and controls remain visible. Records the pause timestamp for
    /// rewind-on-resume and saves progress to persistent storage.
    func pause() {
        audioEngine.pause()
        isPlaying = false
        
        if pauseTimestamp == nil {
            pauseTimestamp = Date()
        }

        // Battery-friendly: do NOT keep a background task running while paused.
        // (We still keep Now Playing metadata + playbackRate=0.0 so the UI stays stable.)
        endBackgroundTask()

        // CRUCIAL: keep Now Playing metadata, but mark paused + playbackRate = 0.0
        updateNowPlayingInfo(isPaused: true)
        syncToWatch()
        
        // Save progress when paused
        if audioEngine.isItemLoaded, let folder = folderURL?.absoluteString, tracks.indices.contains(currentIndex) {
            persistence.saveBookProgress(for: folder, trackId: tracks[currentIndex].id, time: audioEngine.currentTime)
        }
    }

    private func endBackgroundTask() {
        guard pauseBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pauseBackgroundTask)
        pauseBackgroundTask = .invalid
    }

    private func findNextEnabledTrackIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        for i in (currentIndex + 1)..<tracks.count {
            if tracks[i].isEnabled { return i }
        }
        return nil
    }

    private func findPrevEnabledTrackIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        for i in stride(from: currentIndex - 1, through: 0, by: -1) {
            if tracks[i].isEnabled { return i }
        }
        return nil
    }

    private func findNextEnabledChapterIndex(after idx: Int) -> Int? {
        ChapterService.nextEnabledIndex(after: idx, in: chapters)
    }

    private func findPrevEnabledChapterIndex(before idx: Int) -> Int? {
        ChapterService.prevEnabledIndex(before: idx, in: chapters)
    }

    /// Advances to the next enabled track, or loops to the first if at the end.
    /// When chapters are present, delegates to `nextChapter()`.
    func nextTrack() {
        if chapters.count >= 2 {
            nextChapter()
            return
        }
        if let newIndex = findNextEnabledTrackIndex() {
            prepareToPlay(index: newIndex, autoplay: true)
        } else {
            // Loop the entire playlist if we reached the end
            if let firstEnabled = tracks.firstIndex(where: { $0.isEnabled }) {
                prepareToPlay(index: firstEnabled, autoplay: true)
            }
        }
    }

    /// Goes to the previous track, or restarts the current one if more than
    /// 5 seconds have elapsed. When chapters are present, delegates to
    /// `previousChapterOrRestart()`.
    func previousTrackOrRestart() {
        if chapters.count >= 2 {
            previousChapterOrRestart()
            return
        }
        guard !tracks.isEmpty else { return }
        let elapsed = audioEngine.currentTime
        if elapsed.isFinite, elapsed > 5 {
            isManualSeeking = true
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isManualSeeking = false
                    self?.updateCurrentChapterFromPlayerTime()
                }
            }
            updateNowPlayingElapsedTime()
            updateProgressFromPlayer()
            return
        }

        if let newIndex = findPrevEnabledTrackIndex() {
            prepareToPlay(index: newIndex, autoplay: true)
        } else {
            // If it's the first track and elapsed < 5, just restart it.
            isManualSeeking = true
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isManualSeeking = false
                    self?.updateCurrentChapterFromPlayerTime()
                }
            }
        }
    }

    /// Advances to the next enabled chapter. Falls back to `nextTrack()` when
    /// chapters are unavailable or the last chapter is reached.
    func nextChapter() {
        guard chapters.count >= 2 else {
            nextTrack()
            return
        }
        let currentIdx = currentChapterIndex ?? -1
        if let nextIdx = findNextEnabledChapterIndex(after: currentIdx) {
            seekToChapter(at: nextIdx)
        } else {
            if let newIndex = findNextEnabledTrackIndex() {
                prepareToPlay(index: newIndex, autoplay: true)
            } else {
                // Loop the entire playlist if we reached the end
                if let firstEnabled = tracks.firstIndex(where: { $0.isEnabled }) {
                    prepareToPlay(index: firstEnabled, autoplay: true)
                }
            }
        }
    }

    /// Goes to the previous chapter, or restarts the current one if more than
    /// 5 seconds have elapsed. Falls back to `previousTrackOrRestart()` when
    /// chapters are unavailable.
    func previousChapterOrRestart() {
        guard chapters.count >= 2 else {
            previousTrackOrRestart()
            return
        }
        guard audioEngine.isItemLoaded else { return }

        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        if let _ = currentChapterIndex, let current = currentChapterForTime(t), (t - current.startSeconds) > 5 {
            seekToChapter(at: current.index)
            return
        }

        let currentIdx = currentChapterIndex ?? 0
        if let prevIdx = findPrevEnabledChapterIndex(before: currentIdx) {
            seekToChapter(at: prevIdx)
        } else {
            if let firstEnabled = findNextEnabledChapterIndex(after: -1) {
                seekToChapter(at: firstEnabled)
            } else {
                seekToChapter(at: chapters.first?.index ?? 0)
            }
        }
    }

    /// Enabled bookmarks scoped to the current track, excluding those with
    /// non-finite timestamps. Used by bookmark-loop and skip-navigation logic.
    private var enabledCurrentTrackBookmarks: [Bookmark] {
        currentTrackBookmarks.filter { $0.isEnabled && $0.timestamp.isFinite }
    }

    private func jumpToNextBookmark(from currentTime: Double) -> Bool {
        let bookmarks = enabledCurrentTrackBookmarks
        guard let target = bookmarks.first(where: { $0.timestamp > currentTime + 1.0 }) ?? bookmarks.first else {
            return false
        }
        jumpToBookmark(target)
        return true
    }

    private func jumpToPreviousBookmark(from currentTime: Double) -> Bool {
        let bookmarks = enabledCurrentTrackBookmarks
        guard let target = bookmarks.last(where: { $0.timestamp < currentTime - 2.0 }) ?? bookmarks.last else {
            return false
        }
        jumpToBookmark(target)
        return true
    }

    /// Skips to the previous chapter or track. In bookmark loop mode, jumps to the
    /// previous bookmark instead.
    /// - Returns: `true` if the navigation resulted in a bookmark jump.
    @discardableResult
    func skipBackwardNavigation() -> Bool {
        if loopMode == .bookmark,
           audioEngine.currentTime.isFinite,
           jumpToPreviousBookmark(from: audioEngine.currentTime) {
            return true
        }

        if chapters.count >= 2 {
            previousChapterOrRestart()
        } else {
            previousTrackOrRestart()
        }
        return false
    }

    /// Skips to the next chapter or track. In bookmark loop mode, jumps to the
    /// next bookmark instead.
    /// - Returns: `true` if the navigation resulted in a bookmark jump.
    @discardableResult
    func skipForwardNavigation() -> Bool {
        if loopMode == .bookmark,
           audioEngine.currentTime.isFinite,
           jumpToNextBookmark(from: audioEngine.currentTime) {
            return true
        }

        if chapters.count >= 2 {
            nextChapter()
        } else {
            nextTrack()
        }
        return false
    }

    /// Skips backward by 30 seconds (scaled by playback speed). In bookmark loop
    /// mode, jumps to the previous bookmark instead.
    /// - Returns: `true` if the skip resulted in a bookmark jump.
    @discardableResult
    func skipBackward30() -> Bool {
        guard audioEngine.isItemLoaded else { return false }
        let current = audioEngine.currentTime
        guard current.isFinite else { return false }

        if loopMode == .bookmark {
            if jumpToPreviousBookmark(from: current) {
                return true
            }
            if chapters.count >= 2 {
                previousChapterOrRestart()
            } else {
                previousTrackOrRestart()
            }
            return false
        }

        let target = max(0, current - 30)
        isManualSeeking = true
        audioEngine.seek(to:target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
        return false
    }

    /// Skips forward by 30 seconds (scaled by playback speed). In bookmark loop
    /// mode, jumps to the next bookmark instead.
    /// - Returns: `true` if the skip resulted in a bookmark jump.
    @discardableResult
    func skipForward30() -> Bool {
        guard audioEngine.isItemLoaded else { return false }
        let current = audioEngine.currentTime
        guard current.isFinite else { return false }

        if loopMode == .bookmark {
            if jumpToNextBookmark(from: current) {
                return true
            }
            if chapters.count >= 2 {
                nextChapter()
            } else {
                nextTrack()
            }
            return false
        }

        let duration = durationSeconds ?? 0
        let target = min(duration, current + 30)
        isManualSeeking = true
        audioEngine.seek(to:target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
        return false
    }

    /// Seeks to an absolute time position in seconds. Updates Now Playing
    /// metadata, chapter state, and progress after the seek completes.
    /// - Parameter targetSeconds: The target time in seconds.
    func seek(toSeconds targetSeconds: Double) {
        guard audioEngine.isItemLoaded else { return }
        isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isManualSeeking = false
                self.updateCurrentChapterFromPlayerTime()
                self.updateNowPlayingElapsedTime()
                self.updateProgressFromPlayer()
                self.updateCurrentDisplayArtwork(at: targetSeconds, force: true)
                if self.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                }
            }
        }
    }

    private func applyPendingDeepLinkSeekIfPossible() {
        guard let action = deepLinkHandler.applyPendingSeekIfPossible(isItemLoaded: audioEngine.isItemLoaded) else { return }
        if case .seek(let time) = action {
            seek(toSeconds: time)
        }
    }

    /// Seeks to a fractional position (0...1) within the current chapter or
    /// track, depending on what is available.
    /// - Parameter fraction: A value from 0.0 to 1.0 representing the target position.
    func seek(toFraction fraction: Double) {
        let safeFraction = min(1, max(0, fraction))
        
        if chapters.count >= 2, let idx = currentChapterIndex {
            let c = chapters[idx]
            let chapterDuration = c.endSeconds - c.startSeconds
            if chapterDuration > 0 {
                let targetSeconds = c.startSeconds + (chapterDuration * safeFraction)
                seek(toSeconds: targetSeconds)
            }
        } else {
            let duration = durationSeconds ?? 0
            if duration > 0 {
                let targetSeconds = duration * safeFraction
                seek(toSeconds: targetSeconds)
            }
        }
    }

    /// Sets the playback speed and persists the preference for the current book.
    /// - Parameter newSpeed: The desired rate (e.g. 1.0, 1.25, 1.5, 2.0).
    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        if let key = folderURL?.absoluteString {
            persistence.saveSpeed(for: key, speed: speed)
        }
        audioEngine.setSpeed(speed)
        // Ensure speed persists after loops/track changes:
        applySpeedToCurrentItem()
        updateNowPlayingInfo(isPaused: !isPlaying)
        updateProgressFromPlayer()
        syncToWatch()
    }

    /// Toggles volume boost (+9 dB) on or off.
    func setVolumeBoost(enabled: Bool) {
        isVolumeBoostEnabled = enabled
        audioEngine.setVolumeBoost(enabled: enabled)
    }

    /// Sets the loop mode and persists the preference for the current book.
    /// - Parameter mode: The desired loop mode (off, chapter, or bookmark).
    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        if let key = folderURL?.absoluteString {
            persistence.saveLoopMode(for: key, loopMode: mode.rawValue)
        }
        
        syncToWatch()
    }

    /// Cycles through the available loop modes: off → chapter → bookmark → off.
    /// The bookmark mode is skipped when no bookmarks exist.
    func cycleLoopMode() {
        let hasBookmarks = !bookmarks.isEmpty
        switch loopMode {
        case .off:
            setLoopMode(.chapter)
        case .chapter:
            setLoopMode(hasBookmarks ? .bookmark : .off)
        case .bookmark:
            setLoopMode(.off)
        }
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

    private func evaluateSleepTimerAtChapterEnd() {
        sleepTimerManager.evaluateAtChapterEnd()
    }

    private func stop() {
        isPlaying = false
        currentTitle = String(localized: "No track selected")
        progressFraction = 0
        progressText = "--:--"
        elapsedText = "--:--"

        
        
        audioEngine.stop()

        stopCurrentFileSecurityScopeIfNeeded()
    }

    private func prepareToPlay(index: Int, autoplay: Bool) {
        guard tracks.indices.contains(index) else { return }

        // Save progress before changing track
        if let folder = folderURL?.absoluteString, tracks.indices.contains(currentIndex) {
            persistence.saveBookProgress(for: folder, trackId: tracks[currentIndex].id, time: audioEngine.currentTime)
        }

        currentIndex = index
        currentTitle = tracks[index].title
        currentSubtitle = ""
        thumbnailImage = nil
        currentDisplayArtwork = nil
        watchThumbnailData = nil
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
        chapters = []
        currentChapterIndex = nil
        isSeekingForChapterBoundary = false
        isManualSeeking = false
        lastBookmarkCheckSecond = nil

        
        

        // For Files/iCloud-provider URLs:
        startSelectionSecurityScopeIfNeeded()
        stopCurrentFileSecurityScopeIfNeeded()
        startCurrentFileSecurityScopeForURL(tracks[index].url)

        let trackURL = tracks[index].url
        Task { [weak self] in
            guard let self else { return }
            await self.ensureItemIsAvailable(url: trackURL)
        }

        // AudioEngine handles AVPlayerItem creation, observers, and duration loading.
        configureAudioSessionIfNeeded()
        audioEngine.replaceCurrentItem(with: trackURL)

        applySpeedToCurrentItem()
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
    
    private func enforceEnabledState() {
        guard !isManualSeeking else { return }
        if chapters.count >= 2 {
            if let idx = currentChapterIndex, !chapters[idx].isEnabled {
                if let nextIdx = findNextEnabledChapterIndex(after: idx) {
                    seekToChapter(at: nextIdx)
                } else if loopMode == .chapter, let firstIdx = findNextEnabledChapterIndex(after: -1) {
                    seekToChapter(at: firstIdx)
                } else {
                    nextTrack()
                }
            }
        } else {
            if tracks.indices.contains(currentIndex), !tracks[currentIndex].isEnabled {
                nextTrack()
            }
        }
    }

    private func handleTrackEnded() {
        guard audioEngine.isItemLoaded else { return }

        // If the user armed an end-of-chapter sleep timer, the natural file
        // end also counts as the end of the current (last) chapter.
        if case .endOfChapter = sleepTimerMode {
            evaluateSleepTimerAtChapterEnd()
            return
        }

        if chapters.count >= 2 {
            if loopMode == .chapter {
                // If it hits the absolute end of the file, just loop the current (last) chapter.
                if let idx = currentChapterIndex {
                    let c = chapters[idx]
                    let targetSeconds = c.startSeconds + 0.05
                    progressFraction = 0
                    audioEngine.seek(to: targetSeconds) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if self.isPlaying {
                                self.audioEngine.playImmediately(atRate: self.speed)
                                self.applySpeedToCurrentItem()
                            } else {
                                self.updateNowPlayingInfo(isPaused: true)
                            }
                            self.updateProgressFromPlayer()
                        }
                    }
                    return
                }
            }
            nextTrack()
            return
        }

        if loopMode == .chapter {
            progressFraction = 0
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isPlaying {
                        self.audioEngine.playImmediately(atRate: self.speed)
                        self.applySpeedToCurrentItem()
                    } else {
                        self.updateNowPlayingInfo(isPaused: true)
                    }
                    self.updateProgressFromPlayer()
                }
            }
        } else {
            nextTrack()
        }
    }

    private func applySpeedToCurrentItem() {
        // AVAudioUnitVarispeed handles rate natively.
        audioEngine.setSpeed(speed)
        if isPlaying {
            audioEngine.playImmediately(atRate: speed)
        }
    }

    // MARK: AVAudioSession (background audio)

    private func configureAudioSessionIfNeeded() {
        audioEngine.configureAudioSession()
    }

    // MARK: Security-scoped resource handling

    private func startSelectionSecurityScopeIfNeeded() {
        guard hasSelectionSecurityScopeAccess == false else { return }
        guard let url = folderURL else { return }
        selectionSecurityScopeURL = url
        hasSelectionSecurityScopeAccess = url.startAccessingSecurityScopedResource()
    }

    private func stopSelectionSecurityScopeIfNeeded() {
        guard hasSelectionSecurityScopeAccess, let url = selectionSecurityScopeURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasSelectionSecurityScopeAccess = false
        selectionSecurityScopeURL = nil
    }

    private func startCurrentFileSecurityScopeIfNeeded() {
        guard hasCurrentFileSecurityScopeAccess == false else { return }
        guard tracks.indices.contains(currentIndex) else { return }
        let url = tracks[currentIndex].url
        currentFileSecurityScopeURL = url
        hasCurrentFileSecurityScopeAccess = url.startAccessingSecurityScopedResource()
    }

    private func startCurrentFileSecurityScopeForURL(_ url: URL) {
        guard hasCurrentFileSecurityScopeAccess == false else { return }
        currentFileSecurityScopeURL = url
        hasCurrentFileSecurityScopeAccess = url.startAccessingSecurityScopedResource()
    }

    private func stopCurrentFileSecurityScopeIfNeeded() {
        guard hasCurrentFileSecurityScopeAccess, let url = currentFileSecurityScopeURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasCurrentFileSecurityScopeAccess = false
        currentFileSecurityScopeURL = nil
    }

    private func stopAllSecurityScope() {
        stopCurrentFileSecurityScopeIfNeeded()
        stopSelectionSecurityScopeIfNeeded()
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
        if chapters.count >= 2, let idx = currentChapterIndex {
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

        if chapters.count >= 2, let idx = currentChapterIndex {
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
            progressFraction = 0
            progressText = "--:--"
            elapsedText = "--:--"
            return
        }

        let elapsed = audioEngine.currentTime

        if chapters.count >= 2 {
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
                    progressFraction = frac
                    let remaining = max(0, chapterDuration - chapterElapsed) / Double(speed)
                    progressText = "-\(NowPlayingController.formatTime(remaining))"
                    elapsedText = NowPlayingController.formatTime(max(0, chapterElapsed) / Double(speed))
                    if didChange { syncToWatch() }
                    return
                }
            }
        }

        let duration = durationSeconds ?? 0

        guard elapsed.isFinite, duration.isFinite, duration > 0 else {
            progressFraction = 0
            progressText = "--:--"
            elapsedText = "--:--"
            return
        }

        let frac = min(1, max(0, elapsed / duration))
        let didChange = abs(progressFraction - frac) > 0.005
        progressFraction = frac

        let remaining = max(0, duration - elapsed) / Double(speed)
        progressText = "-\(NowPlayingController.formatTime(remaining))"
        elapsedText = NowPlayingController.formatTime(max(0, elapsed) / Double(speed))
        if didChange { syncToWatch() }
    }


    // MARK: iCloud / Files provider helpers

    private func ensureItemIsAvailable(url: URL) async {
        // Best-effort: if it’s an iCloud ubiquitous item, request download.
        // If it’s already local, this is basically a no-op.
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])

            guard values.isUbiquitousItem == true else { return }

            let status = values.ubiquitousItemDownloadingStatus ?? URLUbiquitousItemDownloadingStatus.current
            if status != URLUbiquitousItemDownloadingStatus.current {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        } catch {
            // Keep silent for a beginner skeleton; AVPlayer will surface failure if truly unreadable.
            print("ensureItemIsAvailable error: \(error)")
        }
    }

    private func loadDurationForNowPlaying() async {
        guard let seconds = audioEngine.duration, seconds > 0 else { return }
        durationSeconds = seconds
        updateNowPlayingInfo(isPaused: !isPlaying)
        updateProgressFromPlayer()

        // Once asset is ready, check for saved progress and seek
        if deepLinkHandler.pendingSeekTime != nil {
            await MainActor.run {
                self.applyPendingDeepLinkSeekIfPossible()
            }
        } else if let folder = folderURL?.absoluteString,
           let progress = persistence.getBookProgress(for: folder),
           tracks.indices.contains(currentIndex),
           progress.trackId == tracks[currentIndex].id,
           progress.time > 0, progress.time < seconds {
            let savedTime = progress.time
            await MainActor.run {
                self.isManualSeeking = true
                audioEngine.seek(to: savedTime) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.isManualSeeking = false
                                self?.updateCurrentChapterFromPlayerTime()
                                self?.updateNowPlayingElapsedTime()
                                self?.updateProgressFromPlayer()
                                if let self, self.isPlaying {
                                    self.audioEngine.playImmediately(atRate: self.speed)
                                    self.applySpeedToCurrentItem()
                                }
                            }
                        }
                    }
                }
            }

    private func generateThumbnail(for url: URL) async {
        let sourceImage: UIImage?
        if let embedded = await embeddedArtworkImage(for: url) {
            sourceImage = embedded
        } else if let folderImage = await folderArtworkImage(near: url) {
            sourceImage = folderImage
        } else {
            sourceImage = loadAppIconImage()
        }

        guard let sourceImage else {
            await MainActor.run {
                thumbnailImage = nil
                currentDisplayArtwork = nil
                watchThumbnailData = nil
                baseWatchThumbnailData = nil
                currentDisplayArtworkKey = nil
                updateNowPlayingInfo(isPaused: !isPlaying)
                syncToWatch()
            }
            return
        }

        // Run all UIGraphicsImageRenderer work off the MainActor via a detached task.
        let displayScale = self.displayScale
        let result = await Task.detached(priority: .userInitiated) { () -> (UIImage, Data?) in
            let displaySize = CGSize(width: 300, height: 300)
            let displayFormat = UIGraphicsImageRendererFormat()
            displayFormat.scale = displayScale
            let displayRenderer = UIGraphicsImageRenderer(size: displaySize, format: displayFormat)
            let thumbnailImage = displayRenderer.image { _ in
                sourceImage.draw(in: CGRect(origin: .zero, size: displaySize))
            }

            let watchSize = CGSize(width: 60, height: 60)
            let watchFormat = UIGraphicsImageRendererFormat()
            watchFormat.scale = 1.0
            let watchRenderer = UIGraphicsImageRenderer(size: watchSize, format: watchFormat)
            let watchImage = watchRenderer.image { _ in
                sourceImage.draw(in: CGRect(origin: .zero, size: watchSize))
            }
            let watchThumbnailData = watchImage.jpegData(compressionQuality: 0.6)

            return (thumbnailImage, watchThumbnailData)
        }.value

        // Update @Observable properties back on MainActor
        await MainActor.run {
            thumbnailImage = result.0
            baseWatchThumbnailData = result.1
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
        }
    }

    private func embeddedArtworkImage(for url: URL) async -> UIImage? {
        await ArtworkCache.embeddedArtworkImage(for: url)
    }

    private func folderArtworkImage(near url: URL) async -> UIImage? {
        let folderURL = url.deletingLastPathComponent()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"]
        let imageExtensionSet = Set(imageExtensions)

        let files = listFilesInFolder(folderURL)
        let images = files.filter { fileURL in
            imageExtensionSet.contains(fileURL.pathExtension.lowercased())
        }

        if !images.isEmpty {
            let preferred = images.first { fileURL in
                fileURL.deletingPathExtension().lastPathComponent.lowercased() == "cover"
            }

            let selected = preferred ?? images.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }.first

            if let selected, let image = await loadImageFile(at: selected) {
                return image
            }
        }

        // If directory enumeration is blocked, still try direct cover.* paths.
        for ext in imageExtensions {
            let candidate = folderURL.appendingPathComponent("cover").appendingPathExtension(ext)
            if let image = await loadImageFile(at: candidate) {
                return image
            }
        }

        return nil
    }

    private func listFilesInFolder(_ folderURL: URL) -> [URL] {
        ArtworkCache.listFilesInFolder(folderURL)
    }

    private func loadImageFile(at imageURL: URL) async -> UIImage? {
        await ensureItemIsAvailable(url: imageURL)

        let didStart = imageURL.startAccessingSecurityScopedResource()
        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }

        let maxPixelSize = 600
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func loadChaptersForCurrentItem() async {
        guard audioEngine.isItemLoaded,
              tracks.indices.contains(currentIndex) else { return }
        let asset = AVAsset(url: tracks[currentIndex].url)

        let ext = tracks[currentIndex].url.pathExtension.lowercased()
        guard ext == "m4b" || ext == "m4a" else { return }

        var built = await ChapterService.parseChapters(from: asset)

        let trackKey = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url.absoluteString : ""
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
            chapters = []
            currentChapterIndex = nil
            currentSubtitle = ""
            
            updateNowPlayingInfo(isPaused: !isPlaying)
            syncToWatch()
        }
        computeWordClouds()
    }

    private func updateCurrentChapterFromPlayerTime() {
        guard chapters.count >= 2, audioEngine.isItemLoaded else { return }
        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        // Find all chapters that contain the current time
        let matching = chapters.filter { t >= $0.startSeconds && t < $0.endSeconds }
        
        // Pick the most specific one (shortest duration) to ignore global/overlapping chapters
        if let bestMatch = matching.min(by: { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) }),
           let idx = chapters.firstIndex(of: bestMatch) {
            
            if currentChapterIndex != idx {
                currentChapterIndex = idx
                let c = chapters[idx]
                if let title = c.title, !title.isEmpty {
                    currentSubtitle = title
                } else {
                    currentSubtitle = String(localized: "Chapter \(idx + 1)")
                }
                updateNowPlayingInfo(isPaused: !isPlaying)
                syncToWatch()
            }
        }
    }

    private func currentChapterForTime(_ t: Double) -> Chapter? {
        ChapterService.chapter(forTime: t, in: chapters)
    }

    private func applyChapterLoopIfNeeded() {
        guard !isManualSeeking else { return }
        guard chapters.count >= 2, let idx = currentChapterIndex, audioEngine.isItemLoaded else { return }
        guard !isSeekingForChapterBoundary else { return }

        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        let c = chapters[idx]
        if t >= (c.endSeconds - 0.5) {
            // Honor an armed end-of-chapter sleep timer first.
            if case .endOfChapter = sleepTimerMode {
                evaluateSleepTimerAtChapterEnd()
                return
            }
            if loopMode == .chapter {
                // Loop the CURRENT chapter.
                isSeekingForChapterBoundary = true
                progressFraction = 0
                let targetSeconds = c.startSeconds + 0.05
                audioEngine.seek(to:targetSeconds) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            } else {
                if let nextIdx = findNextEnabledChapterIndex(after: idx) {
                    let nextC = chapters[nextIdx]
                    if abs(nextC.startSeconds - c.endSeconds) < 1.0 && nextIdx == idx + 1 {
                        // Contiguous chapters — let AVPlayer seamlessly continue.
                    } else {
                        // Skip disabled chapters or gaps.
                        isSeekingForChapterBoundary = true
                        progressFraction = 0
                        audioEngine.seek(to:nextC.startSeconds) { [weak self] _ in
                            self?.resumeAfterSeek()
                        }
                    }
                } else {
                    // This is the LAST chapter and loop is OFF. Go to next track.
                    DispatchQueue.main.async { [weak self] in
                        self?.isSeekingForChapterBoundary = false
                        self?.nextTrack()
                    }
                }
            }
        }
    }

    private func applyBookmarkLoopIfNeeded() {
        guard loopMode == .bookmark, !isManualSeeking, !isSeekingForChapterBoundary else { return }
        guard audioEngine.isItemLoaded else { return }
        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        let sorted = currentTrackBookmarks.filter { $0.isEnabled }
        guard sorted.count >= 2 else { return }

        // Strict `<` keeps the end-boundary in the approaching segment so the
        // loop-back fires *before* the segment shifts forward.
        guard let startIdx = sorted.lastIndex(where: { $0.timestamp < t }) else { return }
        let endIdx = startIdx + 1
        guard endIdx < sorted.count else {
            // Playhead overshot the last boundary — loop to the last segment start.
            if sorted.count >= 2, t - sorted[sorted.count - 1].timestamp < 1.0 {
                let lastSegmentStart = sorted.count - 2
                isSeekingForChapterBoundary = true
                audioEngine.seek(to:sorted[lastSegmentStart].timestamp + 0.05) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            }
            return
        }

        // Look-ahead covers one polling interval (0.25 s) scaled by playback speed.
        let lookAhead = max(0.5, 0.3 * Double(speed))
        if t >= sorted[endIdx].timestamp - lookAhead {
            isSeekingForChapterBoundary = true
            audioEngine.seek(to:sorted[startIdx].timestamp + 0.05) { [weak self] _ in
                self?.resumeAfterSeek()
            }
        }
    }

    private func resumeAfterSeek() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSeekingForChapterBoundary = false
            if self.isPlaying {
                self.audioEngine.playImmediately(atRate: self.speed)
                self.applySpeedToCurrentItem()
            } else {
                self.updateNowPlayingInfo(isPaused: true)
            }
            self.updateNowPlayingElapsedTime()
            self.updateCurrentChapterFromPlayerTime()
            self.updateProgressFromPlayer()
        }
    }

    private func seekToChapter(at index: Int) {
        guard chapters.indices.contains(index), audioEngine.isItemLoaded else { return }
        let c = chapters[index]
        
        // Seek slightly past the boundary to avoid rounding errors matching the previous chapter
        let targetSeconds = c.startSeconds + 0.05
        
        isManualSeeking = true
        audioEngine.seek(to:targetSeconds) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
                self?.updateNowPlayingElapsedTime()
                self?.updateProgressFromPlayer()
                if let self, self.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                }
            }
        }
    }

    // MARK: - Bookmarks API

    /// The persistence key for the currently loaded book, derived from the folder
    /// URL or the current track ID. Used to scope bookmark and progress storage.
    private var bookmarksStorageKey: String? {
        if let f = folderURL?.absoluteString { return f }
        if tracks.indices.contains(currentIndex) { return tracks[currentIndex].id }
        return nil
    }

    /// Loads bookmarks from persistent storage for the currently loaded book.
    /// Falls back to an empty list if no storage key is available.
    func loadBookmarksForCurrentBook() {
        guard let key = bookmarksStorageKey else {
            bookmarks = []
            
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
            return
        }
        bookmarks = persistence.loadBookmarks(for: key, folderURL: folderURL).sorted { $0.timestamp < $1.timestamp }
        
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
    }

    private func persistBookmarks() {
        guard let key = bookmarksStorageKey else { return }
        persistence.saveBookmarks(bookmarks, for: key, folderURL: folderURL)
    }

    /// Bookmarks scoped to the currently playing track, sorted by timestamp.
    var currentTrackBookmarks: [Bookmark] {
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        return bookmarks
            .filter { $0.trackId == nil || $0.trackId == trackId }
            .sorted { $0.timestamp < $1.timestamp }
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
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
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
                currentDisplayArtwork = cached.image
                watchThumbnailData = cached.watchData
            } else if let image = UIImage(contentsOfFile: imageURL.path) {
                let watchData = makeWatchThumbnailData(from: image)
                bookmarkArtworkCache[cacheKey] = (image, watchData)
                currentDisplayArtwork = image
                watchThumbnailData = watchData
            } else {
                print("Failed to load bookmark artwork: \(fileName)")
                currentDisplayArtwork = thumbnailImage
                watchThumbnailData = baseWatchThumbnailData
            }
        } else {
            currentDisplayArtwork = thumbnailImage
            watchThumbnailData = baseWatchThumbnailData
        }

        updateNowPlayingInfo(isPaused: !isPlaying)
        syncToWatch()
        currentDisplayArtworkVersion += 1
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
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        // Auto-numbered default title scoped to the current track.
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        let bm = Bookmark(
            title: String(localized: "Bookmark \(scopedCount + 1)"),
            folderKey: folderURL?.absoluteString,
            trackId: trackId,
            timestamp: t
        )
        bookmarks.append(bm)
        bookmarks.sort { $0.timestamp < $1.timestamp }
        persistBookmarks()
        
        return bm
    }

    /// Creates a draft bookmark at the current playback position without
    /// persisting it. Useful for presenting a pre-filled editor before saving.
    /// - Returns: A draft bookmark, or `nil` if playback is unavailable.
    func bookmarkDraftAtCurrentTime() -> BookmarkDraft? {
        guard audioEngine.isItemLoaded else { return nil }
        let t = audioEngine.currentTime
        guard t.isFinite else { return nil }
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        return BookmarkDraft(
            title: String(localized: "Bookmark \(scopedCount + 1)"),
            folderKey: folderURL?.absoluteString,
            trackId: trackId,
            timestamp: t
        )
    }

    /// Appends a bookmark created from a draft, persisting the updated list.
    /// - Parameters:
    ///   - draft: The draft bookmark providing the base metadata.
    ///   - title: The final bookmark title.
    ///   - timestamp: The bookmark timestamp in seconds.
    ///   - note: An optional text note attached to the bookmark.
    ///   - voiceMemoFileName: An optional filename for an attached voice memo.
    /// - Returns: The newly created bookmark.
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
        persistBookmarks()
        
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
        return bm
    }

    /// Updates an existing bookmark's metadata and re-persists the list.
    /// - Parameters:
    ///   - id: The UUID of the bookmark to update.
    ///   - title: The new title.
    ///   - timestamp: The new timestamp in seconds.
    ///   - note: An optional text note.
    ///   - voiceMemoFileName: An optional voice memo filename.
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
        bookmarkArtworkCache.removeAll()
        persistBookmarks()
        
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
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
            ? bookmarks
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
            bookmarks = targetBookmarks
            
        }
    }

    /// Toggles the enabled state of a bookmark. Disabled bookmarks are skipped
    /// during bookmark-loop navigation and voice-memo triggering.
    /// - Parameter id: The UUID of the bookmark to toggle.
    func toggleBookmarkEnabled(id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].isEnabled.toggle()
        persistBookmarks()
        
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
    }

    /// Reorders bookmarks within the list and persists the new ordering.
    /// - Parameters:
    ///   - source: The indices of bookmarks to move.
    ///   - destination: The index to insert the bookmarks at.
    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        persistBookmarks()
        
        updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)
    }

    /// Deletes a bookmark and its associated voice memo file (if any).
    /// Automatically disables bookmark loop mode if no bookmarks remain.
    /// - Parameter id: The UUID of the bookmark to delete.
    func deleteBookmark(id: UUID) {

        if let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            // Clean up the on-disk voice memo if any.
            if let url = bookmarks[idx].voiceMemoURL(in: folderURL) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    os_log(.error, "Failed to remove voice memo: %{private}@", error.localizedDescription)
                }
            }
            if let url = bookmarks[idx].bookmarkImageURL(in: folderURL) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    os_log(.error, "Failed to remove bookmark image: %{private}@", error.localizedDescription)
                }
            }
            bookmarks.remove(at: idx)
            bookmarkArtworkCache.removeAll()
            persistBookmarks()
            
            updateCurrentDisplayArtwork(at: currentPlaybackTime, force: true)

            if loopMode == .bookmark && currentTrackBookmarks.isEmpty {
                setLoopMode(.off)
            }
        }
    }

    /// Jumps playback to a bookmark's timestamp, suppressing the voice-memo
    /// overlay trigger to avoid unwanted playback interruption.
    /// - Parameter bm: The bookmark to jump to.
    func jumpToBookmark(_ bm: Bookmark) {
        // Suppress retrigger when the user manually navigates to a bookmark.
        lastTriggeredBookmarkID = bm.id
        lastTriggeredAtPlayerSecond = bm.timestamp
        seek(toSeconds: bm.timestamp)
    }

    // MARK: Audio Source Switching

    private enum AudioSource { case mainPlayer, voiceMemo }

    /// Explicitly transitions audio between the main AVPlayer and voice memo
    /// engine.  Pausing the primary player first prevents overlapping streams;
    /// reconfiguring the AVAudioSession on each transition ensures routing and
    /// ducking are correct.
    private func switchAudioSource(to source: AudioSource) {
        let session = AVAudioSession.sharedInstance()
        switch source {
        case .voiceMemo:
            audioEngine.pause()
            try? session.setCategory(.playback, mode: .spokenAudio,
                                     options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
            try? session.setActive(true)
        case .mainPlayer:
            voiceMemoPlayerNode?.stop()
            voiceMemoEngine?.stop()
            voiceMemoEngine?.reset()
            voiceMemoProgressTimer?.invalidate()
            voiceMemoProgressTimer = nil
            voiceMemoProgress = 0.0
            voiceMemoPlayerNode = nil
            voiceMemoEngine = nil
            isPlayingVoiceMemo = false
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            try? session.setActive(true)
        }
    }

    // MARK: Voice Memo Interception

    /// Called from the boundary + periodic time observers. Detects when
    /// playback crosses a bookmark with an attached voice memo and intercepts
    /// playback (when `playBookmarksInline` is enabled).
    private func checkBookmarkVoiceMemoTrigger(at currentSeconds: Double, previousSeconds: Double?) {
        guard !isPlayingVoiceMemo, isPlaying, !isManualSeeking else { return }
        // In bookmark-loop mode the player repeatedly traverses bookmark
        // boundaries by design; firing the voice memo each time would create
        // an unwanted overlay loop, so suppress memo triggers entirely.
        guard loopMode != .bookmark else { return }
        guard currentSeconds.isFinite else { return }
        // Honor user preference.
        guard settingsManager?.playBookmarksInline ?? SettingsManager.Defaults.playBookmarksInline else { return }

        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil

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

        guard let bm = candidates.max(by: { $0.timestamp < $1.timestamp }) else { return }

        // Suppress duplicate firings for the same bookmark.
        if lastTriggeredBookmarkID == bm.id,
           abs(currentSeconds - lastTriggeredAtPlayerSecond) < 5 {
            return
        }
        guard let memoURL = bm.voiceMemoURL(in: folderURL),
              FileManager.default.fileExists(atPath: memoURL.path) else { return }

        lastTriggeredBookmarkID = bm.id
        lastTriggeredAtPlayerSecond = currentSeconds
        startVoiceMemoPlayback(url: memoURL)
    }

    private func cachedVoiceMemoGain(for url: URL) -> Float {
        let key = url.absoluteString
        if let cached = voiceMemoGainCache[key] { return cached }
        let gain = voiceMemoGain(for: url)
        voiceMemoGainCache[key] = gain
        return gain
    }

    private func startVoiceMemoPlayback(url: URL) {
        switchAudioSource(to: .voiceMemo)
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
                DispatchQueue.main.async { self?.voiceMemoDidFinish() }
            }
            playerNode.play()

            voiceMemoProgressTimer?.invalidate()
            voiceMemoProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self,
                      let node = self.voiceMemoPlayerNode,
                      node.isPlaying,
                      let lastTime = node.lastRenderTime,
                      let playerTime = node.playerTime(forNodeTime: lastTime)
                else { return }
                let current = Double(playerTime.sampleTime) / playerTime.sampleRate
                self.voiceMemoProgress = min(1.0, max(0.0, current / self.voiceMemoDuration))
            }

            updateNowPlayingInfo(isPaused: true)
        } catch {
            print("Voice memo playback error: \(error)")
            switchAudioSource(to: .mainPlayer)
            if isPlaying {
                audioEngine.playImmediately(atRate: speed)
            }
        }
    }

    /// Stops the currently playing voice memo overlay and resumes main playback.
    func stopVoiceMemo() {
        switchAudioSource(to: .mainPlayer)

        audioEngine.playImmediately(atRate: speed)
        applySpeedToCurrentItem()
        updateNowPlayingInfo(isPaused: false)
    }

    private func voiceMemoDidFinish() {
        switchAudioSource(to: .mainPlayer)

        if isPlaying {
            audioEngine.playImmediately(atRate: speed)
            applySpeedToCurrentItem()
            updateNowPlayingInfo(isPaused: false)
        }
    }

    private func persistSelection(url: URL) {
        // Refresh security scope for the new selection.
        stopSelectionSecurityScopeIfNeeded()
        selectionSecurityScopeURL = url
        hasSelectionSecurityScopeAccess = url.startAccessingSecurityScopedResource()

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
            enforceEnabledState()
            applyChapterLoopIfNeeded()
            applyBookmarkLoopIfNeeded()
            if settingsManager?.playBookmarksInline ?? SettingsManager.Defaults.playBookmarksInline,
               currentTime.isFinite {
                checkBookmarkVoiceMemoTrigger(at: currentTime, previousSeconds: lastBookmarkCheckSecond)
                lastBookmarkCheckSecond = currentTime
            }
        }
    }

    func playbackControllerDidPlayToEnd(_ controller: PlaybackController) {
        handleTrackEnded()
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
