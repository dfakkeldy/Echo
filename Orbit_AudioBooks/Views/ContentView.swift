import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import UIKit
import WatchConnectivity

// MARK: - Beginner notes (Xcode settings you MUST enable)
//
// In Xcode:
// 1) Select your project (blue icon) -> select the app target -> "Signing & Capabilities"
// 2) Click "+ Capability" -> add "Background Modes"
// 3) Check:
//    - "Audio, AirPlay, and Picture in Picture"
//    - (Optional) "Background fetch" (not required for basic audio playback, but you requested it)
//
// Also ensure you have a valid entitlement to play audio in background (Background Modes capability).

// MARK: - Loop Mode

enum LoopMode: String, Codable {
    case off
    case chapter
    case bookmark
}

// MARK: - Model

@Observable
final class PlayerModel: NSObject, WCSessionDelegate {
    struct Track: Identifiable, Equatable {
        var id: String { url.absoluteString }
        let url: URL
        let title: String
        var isEnabled: Bool = true
    }

    struct Chapter: Identifiable, Equatable {
        var id: String { "\(index)-\(title ?? "unknown")" }
        let index: Int
        let title: String?
        let startSeconds: Double
        let endSeconds: Double
        var isEnabled: Bool = true
    }

    // UI state
    var loopMode: LoopMode = .off
    var speed: Float

    private(set) var folderURL: URL?
    var tracks: [Track] = []
    private(set) var currentIndex: Int = 0

    private(set) var isPlaying: Bool = false
    private(set) var currentTitle: String = "No track selected"
    private(set) var currentSubtitle: String = "" // e.g. "Chapter 3: Something"

    // Progress (for UI)
    private(set) var progressFraction: Double = 0.0
    private(set) var progressText: String = "--:--"
    private(set) var elapsedText: String = "--:--"
    private(set) var durationSeconds: Double? = nil
    private(set) var thumbnailImage: UIImage? = nil
    private(set) var watchThumbnailData: Data? = nil

    // Chapters (for .m4b with chapter markers)
    var chapters: [Chapter] = []
    private(set) var currentChapterIndex: Int? = nil
    private var isSeekingForChapterBoundary: Bool = false
    private var isManualSeeking: Bool = false
    
    private var pauseTimestamp: Date? = nil

    // MARK: Bookmarks
    var bookmarks: [Bookmark] = []
    private(set) var isPlayingVoiceMemo: Bool = false
    /// 0...1 progress of the currently playing voice memo, for the overlay UI.
    private(set) var voiceMemoProgress: Double = 0.0
    @ObservationIgnored private var voiceMemoEngine: AVAudioEngine?
    @ObservationIgnored private var voiceMemoPlayerNode: AVAudioPlayerNode?
    @ObservationIgnored private var voiceMemoDuration: Double = 0
    @ObservationIgnored private var voiceMemoProgressTimer: Timer?

    /// Boundary observer that fires when playback hits a bookmark with a memo.
    @ObservationIgnored private var bookmarkBoundaryObserver: Any?
    /// Boundary observer for bookmark-loop endpoints (precise loop-back trigger).
    @ObservationIgnored private var bookmarkLoopBoundaryObserver: Any?
    /// Track timestamps of recently triggered bookmarks to avoid retrigger loops.
    @ObservationIgnored private var lastTriggeredBookmarkID: UUID?
    @ObservationIgnored private var lastTriggeredAtPlayerSecond: Double = -1
    @ObservationIgnored private var lastBookmarkCheckSecond: Double?

    // iOS 26: avoid UIScreen.main usage; set from SwiftUI environment.
    private var displayScale: CGFloat = 2.0

    func setDisplayScale(_ scale: CGFloat) {
        displayScale = scale
    }

    // Playback
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var chapterBoundaryObserver: Any?
    private var interruptionObserver: NSObjectProtocol?

    // Background task used while paused to reduce the chance of the app being
    // evicted from the system "Now Playing" slot during short pauses.
    private var pauseBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Security-scoped access:
    // - Keep the selected folder/file open while the app runs.
    // - Also keep the currently playing file open (some providers require per-file access).
    private var hasSelectionSecurityScopeAccess: Bool = false
    private var selectionSecurityScopeURL: URL?
    private var hasCurrentFileSecurityScopeAccess: Bool = false
    private var currentFileSecurityScopeURL: URL?

    private let persistence = Persistence()

    @ObservationIgnored private var _volumeView: MPVolumeView?

    private func setSystemVolume(_ level: Float) {
        if _volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 0, height: 0))
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = scene.windows.first {
                window.addSubview(view)
            }
            _volumeView = view
        }
        guard let slider = _volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = level
        slider.sendActions(for: .valueChanged)
    }

    override init() {
        speed = 1.25
        super.init()
        UserDefaults.standard.register(defaults: [
            "playBookmarksInline": true,
            "isRewindEnabled": false,
            "rewindPauseSecondsThreshold": 30,
            "rewindAmountAfterSeconds": 10,
            "rewindPauseMinutesThreshold": 5,
            "rewindAmountAfterMinutes": 30,
            "rewindPauseHoursThreshold": 1,
            "rewindAmountAfterHours": 90,
            "rewindHoursToChapterStart": false
        ])
        setupWatchConnectivity()
    }

    private func setupWatchConnectivity() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        handleMessage(message, replyHandler: replyHandler)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleMessage(userInfo)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        handleWatchBookmarkFile(file)
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
                        let sens = UserDefaults.standard.double(forKey: "crownScrubSensitivity")
                        let mult = sens > 0 ? sens : 0.5
                        let current = self.player?.currentTime().seconds ?? 0
                        let duration = self.durationSeconds ?? 0
                        let target = max(0, min(duration, current + (d * 30.0 * mult)))
                        self.seek(toSeconds: target)
                    }
                case "volumeDelta":
                    if let d = message["delta"] as? Double {
                        let sens = UserDefaults.standard.double(forKey: "crownVolumeSensitivity")
                        let mult = sens > 0 ? sens : 0.05
                        let session = AVAudioSession.sharedInstance()
                        let currentVol = session.outputVolume
                        let newVol = max(0, min(1, currentVol + Float(d * 0.4 * mult)))
                        self.setSystemVolume(newVol)
                    }
                case "toggle": self.togglePlayPause()
                case "toggleLoopMode", "cycleLoopMode":
                    self.cycleLoopMode()
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
            if let commandResult {
                reply["commandResult"] = commandResult
            }
            replyHandler?(reply)
        }
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            if let command = applicationContext["command"] as? String {
                if command == "toggle" {
                    self.togglePlayPause()
                }
            }
        }
    }
    
    func syncToWatch() {
        guard WCSession.default.activationState == .activated else { return }

        let context = watchStateContext()

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("Failed to sync to watch: \(error)")
        }
    }

    private func watchStateContext() -> [String: Any] {
        var context: [String: Any] = [:]
        context["isPlaying"] = isPlaying
        context["progressFraction"] = progressFraction
        context["currentTime"] = player?.currentTime().seconds ?? 0
        context["bookmarkStorageKey"] = bookmarksStorageKey
        context["folderKey"] = folderURL?.absoluteString
        if tracks.indices.contains(currentIndex) {
            context["trackId"] = tracks[currentIndex].id
        }
        
        let title = chapters.count >= 2 ? (currentSubtitle.isEmpty ? "Chapter \((currentChapterIndex ?? 0) + 1)" : currentSubtitle) : currentTitle
        context["title"] = title
        
        let crownAction = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"
        context["crownAction"] = crownAction
        context["loopMode"] = loopMode.rawValue
        
        context["watchPage1"] = UserDefaults.standard.string(forKey: "watchPage1") ?? "empty,empty,skipBackward,playPause,skipForward"
        context["watchPage2"] = UserDefaults.standard.string(forKey: "watchPage2") ?? "loopMode,empty,speed,sleepTimer,bookmark"
        context["hasThumbnail"] = watchThumbnailData != nil

        if let data = watchThumbnailData {
            context["thumbnailData"] = data
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
        // `deinit` is not actor-isolated; keep cleanup synchronous.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let chapterBoundaryObserver, let player { player.removeTimeObserver(chapterBoundaryObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        endBackgroundTask()
        stopAllSecurityScope()
    }

    // MARK: Folder + track loading

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

    func moveChapters(from source: IndexSet, to destination: Int) {
        let currentID = (currentChapterIndex != nil && chapters.indices.contains(currentChapterIndex!)) ? chapters[currentChapterIndex!].id : nil
        chapters.move(fromOffsets: source, toOffset: destination)
        if let currentID, let newIdx = chapters.firstIndex(where: { $0.id == currentID }) {
            currentChapterIndex = newIdx
        }
        if let currentTrackURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil {
            persistence.saveOrder(for: currentTrackURL.absoluteString, ids: chapters.map { $0.id })
        }
        installChapterBoundaryObservers()
    }

    func toggleTrackEnabled(at index: Int) {
        tracks[index].isEnabled.toggle()
        if let folderURL = folderURL {
            var states = persistence.loadEnabledState(for: folderURL.absoluteString) ?? [:]
            states[tracks[index].id] = tracks[index].isEnabled
            persistence.saveEnabledState(for: folderURL.absoluteString, states: states)
        }
    }
    
    func toggleChapterEnabled(at index: Int) {
        chapters[index].isEnabled.toggle()
        if let currentTrackURL = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url : nil {
            var states = persistence.loadEnabledState(for: currentTrackURL.absoluteString) ?? [:]
            states[chapters[index].id] = chapters[index].isEnabled
            persistence.saveEnabledState(for: currentTrackURL.absoluteString, states: states)
        }
        installChapterBoundaryObservers()
    }

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
            installChapterBoundaryObservers()
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

    func loadFolder(_ url: URL, autoplay: Bool = true) {
        stop() // stop current playback when selecting a new folder/file

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
        } else {
            currentTitle = "No .mp3/.m4a/.m4b files found"
            updateNowPlayingInfo(isPaused: true) // keep something stable in Now Playing
        }

        persistSelection(url: url)
    }

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
        let defaults = UserDefaults.standard

        let secondsThreshold = defaults.integer(forKey: "rewindPauseSecondsThreshold")
        let secondsAmount = defaults.integer(forKey: "rewindAmountAfterSeconds")

        let minutesThreshold = defaults.integer(forKey: "rewindPauseMinutesThreshold")
        let minutesAmount = defaults.integer(forKey: "rewindAmountAfterMinutes")

        let hoursThreshold = defaults.integer(forKey: "rewindPauseHoursThreshold")
        let hoursAmount = defaults.integer(forKey: "rewindAmountAfterHours")

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
            let legacyThreshold = defaults.integer(forKey: "rewindPauseDuration")
            let legacyAmount = defaults.integer(forKey: "rewindAmount")
            if legacyThreshold > 0, pausedDuration >= Double(legacyThreshold) {
                rewindAmount = legacyAmount
            }
        }

        return Double(rewindAmount)
    }

    private func shouldJumpToChapterStartForHoursLevel(pausedDuration: TimeInterval) -> Bool {
        let defaults = UserDefaults.standard
        let hoursThreshold = defaults.integer(forKey: "rewindPauseHoursThreshold")
        let hoursToChapterStart = defaults.bool(forKey: "rewindHoursToChapterStart")
        return hoursToChapterStart && pausedDuration >= Double(hoursThreshold * 3600)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        // Check for rewind before playing
        if let pausedAt = pauseTimestamp {
            let pausedDuration = Date().timeIntervalSince(pausedAt)
            if UserDefaults.standard.bool(forKey: "isRewindEnabled") {
                if let player = player {
                    let current = player.currentTime().seconds
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
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
        if player == nil { prepareToPlay(index: currentIndex, autoplay: false) }

        configureAudioSessionIfNeeded()
        startSelectionSecurityScopeIfNeeded()
        startCurrentFileSecurityScopeIfNeeded()

        // Ensure the current item is configured for speech-quality playback before starting.
        applySpeedToCurrentItem()

        player?.defaultRate = speed
        player?.rate = speed
        isPlaying = true
        if let currentSecond = player?.currentTime().seconds, currentSecond.isFinite {
            checkBookmarkVoiceMemoTrigger(at: currentSecond, previousSeconds: nil)
            lastBookmarkCheckSecond = currentSecond
        }

        updateNowPlayingInfo(isPaused: false)
        syncToWatch()
    }

    func pause() {
        // CRUCIAL: do NOT deactivate AVAudioSession when paused.
        player?.pause()
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
        if let player = player, let folder = folderURL?.absoluteString, tracks.indices.contains(currentIndex) {
            persistence.saveBookProgress(for: folder, trackId: tracks[currentIndex].id, time: player.currentTime().seconds)
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
        guard chapters.count >= 2 else { return nil }
        for i in (idx + 1)..<chapters.count {
            if chapters[i].isEnabled { return i }
        }
        return nil
    }

    private func findPrevEnabledChapterIndex(before idx: Int) -> Int? {
        guard chapters.count >= 2 else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            if chapters[i].isEnabled { return i }
        }
        return nil
    }

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

    func previousTrackOrRestart() {
        if chapters.count >= 2 {
            previousChapterOrRestart()
            return
        }
        guard !tracks.isEmpty else { return }
        let elapsed = player?.currentTime().seconds ?? 0
        if elapsed.isFinite, elapsed > 5 {
            isManualSeeking = true
            player?.seek(to: .zero) { [weak self] _ in
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
            player?.seek(to: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isManualSeeking = false
                    self?.updateCurrentChapterFromPlayerTime()
                }
            }
        }
    }

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

    func previousChapterOrRestart() {
        guard chapters.count >= 2 else {
            previousTrackOrRestart()
            return
        }
        guard let player else { return }

        let t = player.currentTime().seconds
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

    @discardableResult
    func skipBackwardNavigation() -> Bool {
        if loopMode == .bookmark,
           let current = player?.currentTime().seconds,
           current.isFinite,
           jumpToPreviousBookmark(from: current) {
            return true
        }

        if chapters.count >= 2 {
            previousChapterOrRestart()
        } else {
            previousTrackOrRestart()
        }
        return false
    }

    @discardableResult
    func skipForwardNavigation() -> Bool {
        if loopMode == .bookmark,
           let current = player?.currentTime().seconds,
           current.isFinite,
           jumpToNextBookmark(from: current) {
            return true
        }

        if chapters.count >= 2 {
            nextChapter()
        } else {
            nextTrack()
        }
        return false
    }

    @discardableResult
    func skipBackward30() -> Bool {
        guard let player else { return false }
        let current = player.currentTime().seconds
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

        let target = max(0, current - 30 * Double(speed))
        isManualSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
        return false
    }

    @discardableResult
    func skipForward30() -> Bool {
        guard let player else { return false }
        let current = player.currentTime().seconds
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
        let target = min(duration, current + 30 * Double(speed))
        isManualSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
        return false
    }

    func seek(toSeconds targetSeconds: Double) {
        guard let player else { return }
        isManualSeeking = true
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
                self?.updateNowPlayingElapsedTime()
                self?.updateProgressFromPlayer()
                if self?.isPlaying == true {
                    self?.player?.defaultRate = self?.speed ?? 1.0
                    self?.player?.playImmediately(atRate: self?.speed ?? 1.0)
                    self?.applySpeedToCurrentItem()
                }
            }
        }
    }

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

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        if let key = folderURL?.absoluteString {
            persistence.saveSpeed(for: key, speed: speed)
        }
        // Ensure speed persists after loops/track changes:
        applySpeedToCurrentItem()

        if isPlaying {
            player?.rate = speed
        }
        updateNowPlayingInfo(isPaused: !isPlaying)
        updateProgressFromPlayer()
    }

    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        if let key = folderURL?.absoluteString {
            persistence.saveLoopMode(for: key, loopMode: mode.rawValue)
        }
        installBookmarkLoopBoundaryObserver()
        syncToWatch()
    }

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

    private func stop() {
        player?.pause()
        isPlaying = false
        currentTitle = "No track selected"
        progressFraction = 0
        progressText = "--:--"
        elapsedText = "--:--"

        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        removeChapterBoundaryObserver()
        removeBookmarkLoopBoundaryObserver()
        player = nil

        stopCurrentFileSecurityScopeIfNeeded()
    }

    private func prepareToPlay(index: Int, autoplay: Bool) {
        guard tracks.indices.contains(index) else { return }

        // Save progress before changing track
        if let player = player, let folder = folderURL?.absoluteString, tracks.indices.contains(currentIndex) {
            persistence.saveBookProgress(for: folder, trackId: tracks[currentIndex].id, time: player.currentTime().seconds)
        }

        currentIndex = index
        currentTitle = tracks[index].title
        currentSubtitle = ""
        
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
        chapters = []
        currentChapterIndex = nil
        isSeekingForChapterBoundary = false
        isManualSeeking = false
        lastBookmarkCheckSecond = nil

        // Clean old observers
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        removeChapterBoundaryObserver()
        removeBookmarkLoopBoundaryObserver()

        // For Files/iCloud-provider URLs:
        // - keep the security scope open BEFORE touching the file (creating items, loading duration, etc.)
        // - ensure the file is downloaded (best-effort)
        startSelectionSecurityScopeIfNeeded()
        stopCurrentFileSecurityScopeIfNeeded()
        startCurrentFileSecurityScopeForURL(tracks[index].url)

        let trackURL = tracks[index].url
        Task { [weak self] in
            guard let self else { return }
            await self.ensureItemIsAvailable(url: trackURL)
        }

        let item = AVPlayerItem(url: trackURL)
        // Pitch-preserving time stretch (better for audiobooks at 1.25x).
        // `.timeDomain` generally sounds more natural than `.varispeed` (which changes pitch).
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = 10

        if player == nil {
            player = AVPlayer(playerItem: item)
            player?.automaticallyWaitsToMinimizeStalling = true
        } else {
            player?.replaceCurrentItem(with: item)
        }

        player?.defaultRate = speed

        applySpeedToCurrentItem()
        configureRemoteCommandsIfNeeded()
        attachObserversForCurrentItem()

        // Prime Now Playing metadata even before play (helps show stable controls)
        updateNowPlayingInfo(isPaused: true)
        updateProgressFromPlayer()

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

    private func attachObserversForCurrentItem() {
        guard let item = player?.currentItem else { return }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTrackEnded()
            }
        }

        // Keep Now Playing elapsed time updated (helps Apple Watch UI)
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateNowPlayingElapsedTime()
                self?.updateCurrentChapterFromPlayerTime()
                self?.updateProgressFromPlayer()
                self?.enforceEnabledState()
                self?.applyChapterLoopIfNeeded()
                self?.applyBookmarkLoopIfNeeded()
                if UserDefaults.standard.bool(forKey: "playBookmarksInline"),
                   let self,
                   let t = self.player?.currentTime().seconds,
                   t.isFinite {
                    self.checkBookmarkVoiceMemoTrigger(at: t, previousSeconds: self.lastBookmarkCheckSecond)
                    self.lastBookmarkCheckSecond = t
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
        guard let player else { return }

        if chapters.count >= 2 {
            if loopMode == .chapter {
                // If it hits the absolute end of the file, just loop the current (last) chapter.
                if let idx = currentChapterIndex {
                    let c = chapters[idx]
                    let targetSeconds = c.startSeconds + 0.05
                    progressFraction = 0
                    player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if self.isPlaying {
                                self.player?.defaultRate = self.speed
                                self.player?.playImmediately(atRate: self.speed)
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
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isPlaying {
                        self.player?.defaultRate = self.speed
                        self.player?.playImmediately(atRate: self.speed)
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
        // Keep the pitch-preserving algorithm even after loops/track changes.
        player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
        if isPlaying {
            player?.defaultRate = speed
            player?.rate = speed
        }
    }

    // MARK: AVAudioSession (background audio)

    private func configureAudioSessionIfNeeded() {
        // Configure for background playback.
        // Note: do NOT deactivate on pause (your requirement).
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` is a good fit for audiobooks.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            setupInterruptionObserver()
        } catch {
            // For a skeleton app, we keep this simple.
            // If you want, you can surface this error in the UI later.
            print("AudioSession error: \(error)")
        }
    }

    private func setupInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard
                let userInfo = notification.userInfo,
                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }

            switch type {
            case .began:
                self.pause()
            case .ended:
                let optionsValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        }
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

    private var didConfigureRemoteCommands = false

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()

        // Show only: Play/Pause, Skip Backward (30s), Next Track
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        center.nextTrackCommand.isEnabled = true

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [30]

        // Explicitly DISABLE "Previous Track" and "Skip Forward"
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false

        // Some UIs also show "Change Playback Position" — disable for a simpler Watch UI.
        center.changePlaybackPositionCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipForwardNavigation() }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipBackward30() }
            return .success
        }
    }

    private func updateNowPlayingElapsedTime() {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        
        if chapters.count >= 2, let idx = currentChapterIndex {
            let c = chapters[idx]
            let chapterElapsed = max(0, current - c.startSeconds)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = chapterElapsed
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingInfo(isPaused: Bool) {
        let center = MPNowPlayingInfoCenter.default()

        var info = center.nowPlayingInfo ?? [:]
        
        let elapsed = player?.currentTime().seconds
        
        if chapters.count >= 2, let idx = currentChapterIndex {
            let c = chapters[idx]
            let chapterDuration = c.endSeconds - c.startSeconds
            let chapterElapsed = max(0, (elapsed ?? c.startSeconds) - c.startSeconds)
            
            info[MPMediaItemPropertyTitle] = currentSubtitle.isEmpty ? "Chapter \(idx + 1)" : currentSubtitle
            info[MPMediaItemPropertyAlbumTitle] = currentTitle
            info[MPMediaItemPropertyPlaybackDuration] = chapterDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = chapterElapsed
        } else {
            info[MPMediaItemPropertyTitle] = currentTitle
            if !currentSubtitle.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = currentSubtitle
            } else {
                info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            }
            if let d = durationSeconds, d.isFinite, d > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = d
            }
            if let e = elapsed, e.isFinite {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = e
            }
        }

        if let image = thumbnailImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        // CRUCIAL: do not clear metadata on pause; just set rate appropriately.
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : speed

        center.nowPlayingInfo = info
    }

    private func updateProgressFromPlayer() {
        guard let player else {
            progressFraction = 0
            progressText = "--:--"
            elapsedText = "--:--"
            return
        }

        let elapsed = player.currentTime().seconds

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
                    progressText = "-\(formatTime(remaining))"
                    elapsedText = formatTime(max(0, chapterElapsed) / Double(speed))
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
        progressText = "-\(formatTime(remaining))"
        elapsedText = formatTime(max(0, elapsed) / Double(speed))
        if didChange { syncToWatch() }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
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
        guard let asset = player?.currentItem?.asset else { return }
        do {
            let d = try await asset.load(.duration)
            let seconds = d.seconds
            if seconds.isFinite, seconds > 0 {
                durationSeconds = seconds
                updateNowPlayingInfo(isPaused: !isPlaying)
                updateProgressFromPlayer()
                
                // Once asset is ready, check for saved progress and seek
                if let folder = folderURL?.absoluteString,
                   let progress = persistence.getBookProgress(for: folder),
                   tracks.indices.contains(currentIndex),
                   progress.trackId == tracks[currentIndex].id,
                   progress.time > 0, progress.time < seconds {
                    let savedTime = progress.time
                    await MainActor.run {
                        self.isManualSeeking = true
                        self.player?.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            DispatchQueue.main.async {
                                self?.isManualSeeking = false
                                self?.updateCurrentChapterFromPlayerTime()
                                self?.updateNowPlayingElapsedTime()
                                self?.updateProgressFromPlayer()
                                if self?.isPlaying == true {
                                    self?.player?.defaultRate = self?.speed ?? 1.0
                                    self?.player?.playImmediately(atRate: self?.speed ?? 1.0)
                                    self?.applySpeedToCurrentItem()
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("Duration load error: \(error)")
        }
    }

    private func generateThumbnail(for url: URL) async {
        let image: UIImage?
        if let embedded = await embeddedArtworkImage(for: url) {
            image = embedded
        } else if let folderImage = await folderArtworkImage(near: url) {
            image = folderImage
        } else {
            image = loadAppIconImage()
        }

        thumbnailImage = image

        if let image {
            // Pre-compute watch thumbnail data to avoid re-encoding on every sync.
            let targetSize = CGSize(width: 60, height: 60)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let scaledImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            watchThumbnailData = scaledImage.jpegData(compressionQuality: 0.6)
        } else {
            watchThumbnailData = nil
        }

        updateNowPlayingInfo(isPaused: !isPlaying)
        syncToWatch()
    }

    private func embeddedArtworkImage(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue),
               let image = UIImage(data: data) {
                return image
            }
        }

        return nil
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
        if let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            return files
        }

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        return (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func loadImageFile(at imageURL: URL) async -> UIImage? {
        await ensureItemIsAvailable(url: imageURL)

        let didStart = imageURL.startAccessingSecurityScopedResource()
        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func loadChaptersForCurrentItem() async {
        guard let asset = player?.currentItem?.asset else { return }

        // Only bother for common audiobook container types.
        let ext = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url.pathExtension.lowercased() : ""
        guard ext == "m4b" || ext == "m4a" else { return }

        // Most audiobooks expose chapters via AVAsset timed chapter metadata groups.
        var groups: [AVTimedMetadataGroup] = []
        
        do {
            let locales = try await asset.load(.availableChapterLocales)
            if let firstLocale = locales.first {
                groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: firstLocale,
                    containingItemsWithCommonKeys: []
                )
            } else {
                groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: Locale.current,
                    containingItemsWithCommonKeys: []
                )
            }
        } catch {
            groups = []
        }

        var built: [Chapter] = []
        built.reserveCapacity(groups.count)

        for g in groups {
            let start = g.timeRange.start.seconds
            let end = (g.timeRange.start + g.timeRange.duration).seconds

            var title: String? = nil
            if let item = g.items.first(where: { $0.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue }) {
                title = try? await item.load(.stringValue)
            } else if let item = g.items.first {
                title = try? await item.load(.stringValue)
            }

            if start.isFinite, end.isFinite, end > start {
                built.append(Chapter(index: 0, title: title, startSeconds: start, endSeconds: end))
            }
        }
        
        // Ensure chronological order and exact index alignment
        built.sort { $0.startSeconds < $1.startSeconds }
        for i in 0..<built.count {
            built[i] = Chapter(index: i, title: built[i].title, startSeconds: built[i].startSeconds, endSeconds: built[i].endSeconds)
        }

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
            installChapterBoundaryObservers()
        } else {
            chapters = []
            currentChapterIndex = nil
            currentSubtitle = ""
            removeChapterBoundaryObserver()
            updateNowPlayingInfo(isPaused: !isPlaying)
            syncToWatch()
        }
    }

    private func updateCurrentChapterFromPlayerTime() {
        guard chapters.count >= 2, let player else { return }
        let t = player.currentTime().seconds
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
                    currentSubtitle = "Chapter \(idx + 1)"
                }
                updateNowPlayingInfo(isPaused: !isPlaying)
                syncToWatch()
            }
        }
    }

    private func currentChapterForTime(_ t: Double) -> Chapter? {
        guard chapters.count >= 2 else { return nil }
        let matching = chapters.filter { t >= $0.startSeconds && t < $0.endSeconds }
        return matching.min(by: { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) })
    }

    private func applyChapterLoopIfNeeded() {
        guard !isManualSeeking else { return }
        guard chapters.count >= 2, let idx = currentChapterIndex, let player else { return }
        guard !isSeekingForChapterBoundary else { return }

        let t = player.currentTime().seconds
        guard t.isFinite else { return }

        let c = chapters[idx]
        if t >= (c.endSeconds - 0.5) {
            if loopMode == .chapter {
                // Loop the CURRENT chapter.
                isSeekingForChapterBoundary = true
                progressFraction = 0
                let targetSeconds = c.startSeconds + 0.05
                player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
                        player.seek(to: CMTime(seconds: nextC.startSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
        guard let player else { return }
        let t = player.currentTime().seconds
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
                player.seek(to: CMTime(seconds: sorted[lastSegmentStart].timestamp + 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            }
            return
        }

        // Look-ahead covers one polling interval (0.25 s) scaled by playback speed.
        let lookAhead = max(0.5, 0.3 * Double(speed))
        if t >= sorted[endIdx].timestamp - lookAhead {
            isSeekingForChapterBoundary = true
            player.seek(to: CMTime(seconds: sorted[startIdx].timestamp + 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.resumeAfterSeek()
            }
        }
    }

    private func removeBookmarkLoopBoundaryObserver() {
        if let bookmarkLoopBoundaryObserver, let player {
            player.removeTimeObserver(bookmarkLoopBoundaryObserver)
        }
        bookmarkLoopBoundaryObserver = nil
    }

    private func installBookmarkLoopBoundaryObserver() {
        removeBookmarkLoopBoundaryObserver()
        guard let player, loopMode == .bookmark else { return }
        let sorted = currentTrackBookmarks.filter { $0.isEnabled }
        guard sorted.count >= 2 else { return }

        let times: [NSValue] = sorted.dropFirst().compactMap { bm in
            let boundary = bm.timestamp - 0.05
            guard boundary > 0, boundary.isFinite else { return nil }
            return NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600))
        }
        guard !times.isEmpty else { return }

        bookmarkLoopBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            self?.applyBookmarkLoopIfNeeded()
        }
    }

    private func removeChapterBoundaryObserver() {
        if let chapterBoundaryObserver, let player {
            player.removeTimeObserver(chapterBoundaryObserver)
        }
        chapterBoundaryObserver = nil
    }

    private func installChapterBoundaryObservers() {
        removeChapterBoundaryObserver()
        guard let player, chapters.count >= 2 else { return }

        let times: [NSValue] = chapters.compactMap { c in
            guard c.isEnabled else { return nil }
            let boundary = c.endSeconds - 0.5
            guard boundary > 0, boundary.isFinite else { return nil }
            return NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600))
        }
        guard !times.isEmpty else { return }

        chapterBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            self?.applyChapterLoopIfNeeded()
        }
    }

    private func resumeAfterSeek() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSeekingForChapterBoundary = false
            if self.isPlaying {
                self.player?.defaultRate = self.speed
                self.player?.playImmediately(atRate: self.speed)
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
        guard chapters.indices.contains(index), let player else { return }
        let c = chapters[index]
        
        // Seek slightly past the boundary to avoid rounding errors matching the previous chapter
        let targetSeconds = c.startSeconds + 0.05
        
        isManualSeeking = true
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
                self?.updateNowPlayingElapsedTime()
                self?.updateProgressFromPlayer()
                if self?.isPlaying == true {
                    self?.player?.defaultRate = self?.speed ?? 1.0
                    self?.player?.playImmediately(atRate: self?.speed ?? 1.0)
                    self?.applySpeedToCurrentItem()
                }
            }
        }
    }

    // MARK: - Bookmarks API

    /// Key used to store bookmarks for the currently loaded book.
    private var bookmarksStorageKey: String? {
        if let f = folderURL?.absoluteString { return f }
        if tracks.indices.contains(currentIndex) { return tracks[currentIndex].id }
        return nil
    }

    func loadBookmarksForCurrentBook() {
        guard let key = bookmarksStorageKey else {
            bookmarks = []
            installBookmarkBoundaryObserver()
            return
        }
        bookmarks = persistence.loadBookmarks(for: key).sorted { $0.timestamp < $1.timestamp }
        installBookmarkBoundaryObserver()
    }

    private func persistBookmarks() {
        guard let key = bookmarksStorageKey else { return }
        persistence.saveBookmarks(bookmarks, for: key)
    }

    /// Bookmarks scoped to the currently playing track (if any), sorted.
    var currentTrackBookmarks: [Bookmark] {
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        return bookmarks
            .filter { $0.trackId == nil || $0.trackId == trackId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    func addBookmarkAtCurrentTime() -> Bookmark? {
        guard let player else { return nil }
        let t = player.currentTime().seconds
        guard t.isFinite else { return nil }
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        // Auto-numbered default title scoped to the current track.
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        let bm = Bookmark(
            title: "Bookmark \(scopedCount + 1)",
            folderKey: folderURL?.absoluteString,
            trackId: trackId,
            timestamp: t
        )
        bookmarks.append(bm)
        bookmarks.sort { $0.timestamp < $1.timestamp }
        persistBookmarks()
        installBookmarkBoundaryObserver()
        return bm
    }

    func bookmarkDraftAtCurrentTime() -> BookmarkDraft? {
        guard let player else { return nil }
        let t = player.currentTime().seconds
        guard t.isFinite else { return nil }
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        let scopedCount = bookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count
        return BookmarkDraft(
            title: "Bookmark \(scopedCount + 1)",
            folderKey: folderURL?.absoluteString,
            trackId: trackId,
            timestamp: t
        )
    }

    @discardableResult
    func appendBookmark(
        from draft: BookmarkDraft,
        title: String,
        timestamp: TimeInterval,
        note: String?,
        voiceMemoFileName: String?
    ) -> Bookmark {
        let bm = Bookmark(
            id: draft.id,
            title: title,
            folderKey: draft.folderKey,
            trackId: draft.trackId,
            timestamp: timestamp,
            note: note,
            voiceMemoFileName: voiceMemoFileName
        )
        bookmarks.append(bm)
        bookmarks.sort { $0.timestamp < $1.timestamp }
        persistBookmarks()
        installBookmarkBoundaryObserver()
        return bm
    }

    func updateBookmark(id: UUID, title: String, timestamp: TimeInterval, note: String?, voiceMemoFileName: String?) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].title = title
        bookmarks[idx].timestamp = timestamp
        bookmarks[idx].note = note
        bookmarks[idx].voiceMemoFileName = voiceMemoFileName
        bookmarks.sort { $0.timestamp < $1.timestamp }
        persistBookmarks()
        installBookmarkBoundaryObserver()
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
        var targetBookmarks = isCurrentBook ? bookmarks : persistence.loadBookmarks(for: storageKey)
        let scopedCount = targetBookmarks.filter { $0.trackId == nil || $0.trackId == trackId }.count

        let bookmark = Bookmark(
            title: "Bookmark \(scopedCount + 1)",
            folderKey: folderKey,
            trackId: trackId,
            timestamp: timestamp,
            note: note?.isEmpty == true ? nil : note,
            voiceMemoFileName: voiceMemoFileName
        )

        targetBookmarks.append(bookmark)
        targetBookmarks.sort { $0.timestamp < $1.timestamp }
        persistence.saveBookmarks(targetBookmarks, for: storageKey)

        if isCurrentBook {
            bookmarks = targetBookmarks
            installBookmarkBoundaryObserver()
        }
    }

    func toggleBookmarkEnabled(id: UUID) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[idx].isEnabled.toggle()
        persistBookmarks()
        installBookmarkBoundaryObserver()
    }

    /// Reorder bookmarks. Only meaningful for bookmarks that share the same
    /// scope (e.g. the current track), since their natural ordering is by
    /// timestamp. Persists the new ordering and refreshes the boundary observer.
    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        persistBookmarks()
        installBookmarkBoundaryObserver()
    }

    func deleteBookmark(id: UUID) {

        if let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            // Clean up the on-disk voice memo if any.
            if let url = bookmarks[idx].voiceMemoURL(in: folderURL) {
                try? FileManager.default.removeItem(at: url)
            }
            bookmarks.remove(at: idx)
            persistBookmarks()
            installBookmarkBoundaryObserver()

            if loopMode == .bookmark && bookmarks.isEmpty {
                setLoopMode(.off)
            }
        }
    }

    /// Install a boundary observer that fires precisely when playback crosses
    /// any bookmark with an attached voice memo, in addition to the
    /// periodic-observer-based safety net. Boundary observers are far more
    /// precise than 0.25s polling.
    private func installBookmarkBoundaryObserver() {
        if let bookmarkBoundaryObserver, let player {
            player.removeTimeObserver(bookmarkBoundaryObserver)
        }
        bookmarkBoundaryObserver = nil
        guard let player else { return }
        let trackId = tracks.indices.contains(currentIndex) ? tracks[currentIndex].id : nil
        let times: [NSValue] = bookmarks.compactMap { bm in
            guard bm.isEnabled, bm.voiceMemoFileName != nil else { return nil }
            if let bt = bm.trackId, let ct = trackId, bt != ct { return nil }
            guard bm.timestamp.isFinite, bm.timestamp > 0 else { return nil }
            return NSValue(time: CMTime(seconds: bm.timestamp, preferredTimescale: 600))
        }
        guard !times.isEmpty else {
            installBookmarkLoopBoundaryObserver()
            return
        }
        bookmarkBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            guard let self, let t = self.player?.currentTime().seconds else { return }
            self.checkBookmarkVoiceMemoTrigger(at: t, previousSeconds: self.lastBookmarkCheckSecond)
            self.lastBookmarkCheckSecond = t
        }
        installBookmarkLoopBoundaryObserver()
    }

    /// Jump playback to a bookmark's timestamp (without firing the voice memo overlay).
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
            player?.pause()
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
        guard currentSeconds.isFinite else { return }
        // Honor user preference.
        guard UserDefaults.standard.bool(forKey: "playBookmarksInline") else { return }

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

    private func startVoiceMemoPlayback(url: URL) {
        switchAudioSource(to: .voiceMemo)
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            engine.mainMixerNode.outputVolume = voiceMemoGain(for: url)

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
                player?.playImmediately(atRate: speed)
            }
        }
    }

    func stopVoiceMemo() {
        switchAudioSource(to: .mainPlayer)

        player?.play()
        applySpeedToCurrentItem()
        updateNowPlayingInfo(isPaused: false)
    }

    private func voiceMemoDidFinish() {
        switchAudioSource(to: .mainPlayer)

        if isPlaying {
            player?.playImmediately(atRate: speed)
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

// MARK: - Folder picker (Files app)

struct FolderPicker: UIViewControllerRepresentable {
    let onPickFolder: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let m4bType = UTType(filenameExtension: "m4b") ?? .audio
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, m4bType, .audio], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickFolder: onPickFolder)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickFolder: (URL) -> Void

        init(onPickFolder: @escaping (URL) -> Void) {
            self.onPickFolder = onPickFolder
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPickFolder(url)
        }
    }
}

// MARK: - UI (single screen)

struct CustomFontModifier: ViewModifier {
    @AppStorage("appFont") private var appFont = "Helvetica"
    var style: Font.TextStyle
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        
        if appFont == "Helvetica" {
            return AnyView(content.font(.system(style, design: .default, weight: weight)))
        } else {
            return AnyView(content.font(.custom(appFont, size: size, relativeTo: style).weight(weight)))
        }
    }
}

extension View {
    func customFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        self.modifier(CustomFontModifier(style: style, weight: weight))
    }

    func accessibleButton(_ label: String) -> some View {
        self.accessibilityLabel(label)
    }

}

struct ContentView: View {
    @State private var model = PlayerModel()
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("appFont") private var appFont = "Helvetica"
    @State private var showingFolderPicker = false
    @State private var showingPlaylist = false
    @State private var showingSettings = false
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0.0
    @State private var newBookmarkDraft: BookmarkDraft? = nil
    @State private var editingBookmarkID: UUID? = nil
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
            ZStack {
            // MARK: Primary player UI (single block — gets the gray-out treatment)
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 12) {
                if let image = model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                        .padding(.horizontal, 16)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 80, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .center, spacing: 6) {
                    Text(model.chapters.count >= 2 ? "Current Chapter" : "Current Title")
                        .customFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.chapters.count >= 2 ? (model.currentSubtitle.isEmpty ? "Chapter \(model.currentChapterIndex ?? 0 + 1)" : model.currentSubtitle) : model.currentTitle)
                        .customFont(.title2, weight: .semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            if model.chapters.count >= 2 {
                Text("Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)")
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
            } else if !model.tracks.isEmpty {
                Text("Track \(model.currentIndex + 1) of \(model.tracks.count)")
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(model.elapsedText)
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                
                Slider(
                    value: $scrubFraction,
                    in: 0...1,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            model.seek(toFraction: scrubFraction)
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .tint(.primary)
                .onChange(of: model.progressFraction) { _, newValue in
                    if !isScrubbing {
                        scrubFraction = newValue
                    }
                }
                
                Text(model.progressText)
                    .customFont(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                
                Button {
                    let didJumpToBookmark = model.skipBackwardNavigation()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.chapters.count >= 2 ? "Previous chapter" : "Previous track")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipBackward30()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Skip back 30 seconds")

                Spacer()

                Button {
                    model.togglePlayPause()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 76, height: 76)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipForward30()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Skip forward 30 seconds")

                Spacer()

                Button {
                    let didJumpToBookmark = model.skipForwardNavigation()
                    UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.chapters.count >= 2 ? "Next chapter" : "Next track")
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            }
            // Apply gray-out + opacity to the ENTIRE primary player block at once.
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            // Single floating "Playing Voice Memo" badge centered over the
            // grayed-out player block.
            if model.isPlayingVoiceMemo {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    Text("Playing Voice Memo")
                        .customFont(.headline)
                    Button {
                        model.stopVoiceMemo()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop voice memo")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .transition(.opacity.combined(with: .scale))
                .overlay(alignment: .bottom) {
                    ProgressView(value: model.voiceMemoProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .padding(.bottom, -22)
                }
            }

            }
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)

            // Custom Bottom Toolbar to avoid UIKitToolbar errors
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        model.cycleLoopMode()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        ZStack {
                            switch model.loopMode {
                            case .off:
                                Image(systemName: "infinity.circle")
                                    .font(.title2)
                            case .chapter:
                                Image(systemName: "infinity.circle.fill")
                                    .font(.title2)
                            case .bookmark:
                                Image(systemName: "arrow.trianglehead.clockwise")
                                    .font(.title2)
                                    .overlay(
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 9, weight: .bold))
                                    )
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Loop mode")
                    .accessibilityValue({
                        switch model.loopMode {
                        case .off: return "Off"
                        case .chapter: return "Chapter"
                        case .bookmark: return "Bookmark"
                        }
                    }())

                    Spacer()

                    Button {
                        let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 10.0]
                        if let index = speeds.firstIndex(of: model.speed) {
                            let nextIndex = (index + 1) % speeds.count
                            model.setSpeed(speeds[nextIndex])
                        } else {
                            model.setSpeed(1.0)
                        }
                    } label: {
                        Text(String(format: "%gx", model.speed))
                            .customFont(.headline)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Playback speed, \(String(format: "%g", model.speed)) times")

                    Spacer()

                    Button {
                        if let draft = model.bookmarkDraftAtCurrentTime() {
                            newBookmarkDraft = draft
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add bookmark at current time")
                    .disabled(model.tracks.isEmpty)

                    Spacer()

                    Button {
                        showingPlaylist = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Playlist")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // Use native bar material for background to match HIG natively without the UIKit warning
            .background(.bar)
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
        .padding(.horizontal)
        .padding(.top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Open folder")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.loadFolder(url)
            }
        }
        .sheet(isPresented: $showingPlaylist) {
            PlaylistView(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .sheet(item: Binding(
            get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
            set: { editingBookmarkID = $0?.id }
        )) { wrapper in
            EditBookmarkView(model: model, bookmarkID: wrapper.id, draft: nil)
        }
        .sheet(item: $newBookmarkDraft) { draft in
            EditBookmarkView(model: model, bookmarkID: nil, draft: draft)
        }
        .onAppear {
            // Configure remote commands early so the Watch/Now Playing UI is stable once audio starts.
            // (The model also guards to configure only once.)
            model.setDisplayScale(displayScale)
            model.restoreLastSelectionIfPossible()
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: PlayerModel
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("appFont") private var appFont = "Helvetica"
    @Environment(\.dismiss) private var dismiss

    @State private var localCrownAction: String = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Appearance") {
                        Form {
                            Section {
                                Toggle("Dark Mode", isOn: $isDarkMode)
                            }
                            Section {
                                Picker("Font", selection: $appFont) {
                                    Text("Helvetica").tag("Helvetica")
                                    Text("OpenDyslexic").tag("OpenDyslexic")
                                    Text("Lexend").tag("Lexend")
                                }
                            }
                        }
                        .navigationTitle("Appearance")
                    }
                }
                Section {
                    NavigationLink("Watch App") {
                        WatchAppSettingsView(model: model)
                    }
                }
                Section {
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }
                Section(footer: Text("When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp.")) {
                    Toggle("Play Bookmarks Inline", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "playBookmarksInline") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "playBookmarksInline") }
                    ))
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

private struct SmartRewindSettingsView: View {
    @AppStorage("isRewindEnabled") private var isRewindEnabled = false
    @AppStorage("rewindPauseSecondsThreshold") private var rewindPauseSecondsThreshold = 30
    @AppStorage("rewindAmountAfterSeconds") private var rewindAmountAfterSeconds = 10
    @AppStorage("rewindPauseMinutesThreshold") private var rewindPauseMinutesThreshold = 5
    @AppStorage("rewindAmountAfterMinutes") private var rewindAmountAfterMinutes = 30
    @AppStorage("rewindPauseHoursThreshold") private var rewindPauseHoursThreshold = 1
    @AppStorage("rewindAmountAfterHours") private var rewindAmountAfterHours = 90
    @AppStorage("rewindHoursToChapterStart") private var rewindHoursToChapterStart = false

    var body: some View {
        Form {
            Section(
                footer: Text("Automatically rewinds on resume. Longer pause rules override shorter pause rules.")
            ) {
                Toggle("Enable Smart Rewind", isOn: $isRewindEnabled)
            }

            if isRewindEnabled {
                Section("Short Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseSecondsThreshold,
                        range: 5...300,
                        step: 5,
                        valueText: "\(rewindPauseSecondsThreshold)s"
                    )
                    InlineStepperRow(
                        title: "Rewind by:",
                        value: $rewindAmountAfterSeconds,
                        range: 5...180,
                        step: 5,
                        valueText: "\(rewindAmountAfterSeconds)s"
                    )
                }

                Section("Medium Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseMinutesThreshold,
                        range: 1...120,
                        step: 1,
                        valueText: "\(rewindPauseMinutesThreshold)m"
                    )
                    InlineStepperRow(
                        title: "Rewind by:",
                        value: $rewindAmountAfterMinutes,
                        range: 10...600,
                        step: 5,
                        valueText: "\(rewindAmountAfterMinutes)s"
                    )
                }

                Section("Long Pauses") {
                    InlineStepperRow(
                        title: "Trigger after:",
                        value: $rewindPauseHoursThreshold,
                        range: 1...24,
                        step: 1,
                        valueText: "\(rewindPauseHoursThreshold)h"
                    )
                    if !rewindHoursToChapterStart {
                        InlineStepperRow(
                            title: "Rewind by:",
                            value: $rewindAmountAfterHours,
                            range: 15...3600,
                            step: 15,
                            valueText: "\(rewindAmountAfterHours)s"
                        )
                    }
                    Toggle("Jump to chapter start", isOn: $rewindHoursToChapterStart)
                }
            }
        }
        .navigationTitle("Smart Rewind")
    }
}

private struct InlineStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let valueText: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .center)

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            .accessibilityHint("Use minus and plus buttons to adjust")
        }
    }
}

/// A wrapper to make UUID Identifiable for use with `.sheet(item:)`.
struct IdentifiableUUID: Identifiable, Hashable {
    let id: UUID
}

/// A unified row in the playlist that mixes chapters, tracks, and bookmarks
/// in chronological order.
private enum PlaylistRow: Identifiable {
    case chapter(index: Int, chapter: PlayerModel.Chapter)
    case track(index: Int, track: PlayerModel.Track)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .chapter(_, let c): return "chapter-\(c.id)"
        case .track(_, let t):   return "track-\(t.id)"
        case .bookmark(let b):   return "bookmark-\(b.id.uuidString)"
        }
    }

    var sortKey: Double {
        switch self {
        case .chapter(_, let c): return c.startSeconds
        case .track(let i, _):   return Double(i) // track ordering
        case .bookmark(let b):   return b.timestamp
        }
    }
}

struct PlaylistView: View {
    @Bindable var model: PlayerModel
    @AppStorage("appFont") private var appFont = "Helvetica"
    @Environment(\.dismiss) private var dismiss
    @State private var editingBookmarkID: UUID? = nil

    private enum PlaylistTab: Hashable { case items, bookmarks }
    @State private var selectedTab: PlaylistTab
    @State private var showChapters: Bool = false

    init(model: PlayerModel) {
        self.model = model
        _selectedTab = State(initialValue: model.loopMode == .bookmark ? .bookmarks : .items)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        } else {
            return "\(m)m"
        }
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Indices into `model.bookmarks` for the bookmarks that are visible in the
    /// current track scope (i.e. those returned by `currentTrackBookmarks`).
    private var visibleBookmarkIndices: [Int] {
        let trackId = model.tracks.indices.contains(model.currentIndex) ? model.tracks[model.currentIndex].id : nil
        return model.bookmarks.indices.filter { i in
            let bm = model.bookmarks[i]
            return bm.trackId == nil || bm.trackId == trackId
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    Text(model.chapters.count >= 2 ? "Chapters" : "Tracks").tag(PlaylistTab.items)
                    Text("Bookmarks").tag(PlaylistTab.bookmarks)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == .items {
                    List {
                        if model.chapters.count >= 2 {
                            ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                                chapterRow(index: index, chapter: chapter)
                            }
                            .onMove { source, destination in
                                model.moveChapters(from: source, to: destination)
                            }
                        } else {
                            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                                trackRow(index: index, track: track)
                            }
                            .onMove { source, destination in
                                model.moveTracks(from: source, to: destination)
                            }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                } else {
                    let sortedBookmarks: [Bookmark] = {
                        let trackId = model.tracks.indices.contains(model.currentIndex) ? model.tracks[model.currentIndex].id : nil
                        return model.bookmarks
                            .filter { $0.trackId == nil || $0.trackId == trackId }
                            .sorted { $0.timestamp < $1.timestamp }
                    }()

                    if sortedBookmarks.isEmpty && !showChapters {
                        ContentUnavailableView(
                            "No Bookmarks",
                            systemImage: "bookmark",
                            description: Text("Tap the bookmark button while playing to save a moment.")
                        )
                    } else {
                        List {
                            if model.chapters.count >= 2 {
                                Toggle("Show Chapters", isOn: $showChapters)
                            }

                            if showChapters {
                                Section("Chapters") {
                                    ForEach(model.chapters) { chapter in
                                        Button {
                                            model.seek(toSeconds: chapter.startSeconds + 0.05)
                                        } label: {
                                            HStack {
                                                Image(systemName: "list.bullet")
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 22)
                                                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                                                Spacer()
                                                Text(formatHMS(chapter.startSeconds))
                                                    .customFont(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                        }
                                    }
                                }
                            }

                            if !sortedBookmarks.isEmpty {
                                Section(showChapters ? "Bookmarks" : "") {
                                    ForEach(sortedBookmarks, id: \.id) { bm in
                                        bookmarkRow(bm)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playlist")


            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        model.resetPlaylist()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingBookmarkID.map { IdentifiableUUID(id: $0) } },
                set: { editingBookmarkID = $0?.id }
            )) { wrapper in
                EditBookmarkView(model: model, bookmarkID: wrapper.id, draft: nil)
            }
        }
        .environment(\.font, appFont == "Helvetica" ? .body : .custom(appFont, size: 17, relativeTo: .body))
    }

    @ViewBuilder
    private func chapterRow(index: Int, chapter: PlayerModel.Chapter) -> some View {
        Button {
            model.toggleChapterEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                Spacer()
                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                    .customFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func trackRow(index: Int, track: PlayerModel.Track) -> some View {
        Button {
            model.toggleTrackEnabled(at: index)
        } label: {
            HStack {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(track.title)
            }
            .foregroundStyle(track.isEnabled ? .primary : .tertiary)
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: Bookmark) -> some View {
        Button {
            model.jumpToBookmark(bm)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: bm.voiceMemoFileName != nil ? "mic.fill" : "note.text")
                    .foregroundStyle(bm.isEnabled ? (bm.voiceMemoFileName != nil ? Color.red : Color.accentColor) : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bm.title.isEmpty ? "Bookmark" : bm.title)
                        .lineLimit(1)
                    Text(formatHMS(bm.timestamp))
                        .customFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
            }
            .foregroundStyle(bm.isEnabled ? .primary : .tertiary)
        }
        .listRowBackground(Color.accentColor.opacity(bm.isEnabled ? 0.06 : 0.02))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleBookmarkEnabled(id: bm.id)
            } label: {
                Label(bm.isEnabled ? "Disable" : "Enable", systemImage: bm.isEnabled ? "bookmark.slash" : "bookmark")
            }
            .tint(bm.isEnabled ? .orange : .green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.deleteBookmark(id: bm.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingBookmarkID = bm.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}


// MARK: - Persistence helper

private struct Persistence {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "AuDioHD.selection.bookmark"
    private let progressKey = "AuDioHD.progress.dictionary"
    private let speedKey = "AuDioHD.playback.speed.dictionary"
    private let loopModeKey = "AuDioHD.playback.loopMode.dictionary"
    private let lastTrackKey = "AuDioHD.lastTrack.dictionary"
    
    func saveLastTrack(for folderKey: String, trackId: String) {
        var dict = defaults.dictionary(forKey: lastTrackKey) as? [String: String] ?? [:]
        dict[folderKey] = trackId
        defaults.set(dict, forKey: lastTrackKey)
    }
    
    func getLastTrack(for folderKey: String) -> String? {
        let dict = defaults.dictionary(forKey: lastTrackKey) as? [String: String] ?? [:]
        return dict[folderKey]
    }
    
    func saveSpeed(for title: String, speed: Float) {
        var dict = defaults.dictionary(forKey: speedKey) as? [String: Float] ?? [:]
        dict[title] = speed
        defaults.set(dict, forKey: speedKey)
    }
    
    func getSpeed(for title: String) -> Float? {
        let dict = defaults.dictionary(forKey: speedKey) as? [String: Float] ?? [:]
        return dict[title]
    }
    
    func saveLoopMode(for key: String, loopMode: String) {
        var dict = defaults.dictionary(forKey: loopModeKey) as? [String: String] ?? [:]
        dict[key] = loopMode
        defaults.set(dict, forKey: loopModeKey)
    }

    func getLoopMode(for key: String) -> String? {
        let dict = defaults.dictionary(forKey: loopModeKey) as? [String: String] ?? [:]
        return dict[key]
    }

    func saveOrder(for key: String, ids: [String]) {
        defaults.set(ids, forKey: "order_\(key)")
    }
    
    func loadOrder(for key: String) -> [String]? {
        defaults.stringArray(forKey: "order_\(key)")
    }
    
    func saveEnabledState(for key: String, states: [String: Bool]) {
        defaults.set(states, forKey: "enabled_\(key)")
    }
    
    func loadEnabledState(for key: String) -> [String: Bool]? {
        defaults.dictionary(forKey: "enabled_\(key)") as? [String: Bool]
    }

    func saveBookProgress(for folderKey: String, trackId: String, time: Double) {
        var dict = defaults.dictionary(forKey: progressKey) as? [String: [String: Any]] ?? [:]
        dict[folderKey] = ["trackId": trackId, "time": time]
        defaults.set(dict, forKey: progressKey)
    }

    func getBookProgress(for folderKey: String) -> (trackId: String, time: Double)? {
        let dict = defaults.dictionary(forKey: progressKey) as? [String: [String: Any]] ?? [:]
        if let item = dict[folderKey], let trackId = item["trackId"] as? String, let time = item["time"] as? Double {
            return (trackId, time)
        }
        return nil
    }

    func saveBookmark(url: URL) {
        do {
            let data = try url.bookmarkData(
                // iOS does not support `.withSecurityScope` bookmarks; the security scope is applied
                // when you call `startAccessingSecurityScopedResource()` on the resolved URL.
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: bookmarkKey)
        } catch {
            print("Bookmark save failed: \(error)")
        }
    }

    // MARK: - Bookmarks (per-book) persistence

    private func bookmarksKey(for key: String) -> String { "bookmarks_\(key)" }

    func saveBookmarks(_ bookmarks: [Bookmark], for key: String) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: bookmarksKey(for: key))
        } catch {
            print("Bookmark encode failed: \(error)")
        }
    }

    func loadBookmarks(for key: String) -> [Bookmark] {
        guard let data = defaults.data(forKey: bookmarksKey(for: key)) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    func restoreBookmark() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            // If stale, resave a fresh bookmark (best-effort).
            if isStale {
                saveBookmark(url: url)
            }

            return url
        } catch {
            print("Bookmark restore failed: \(error)")
            return nil
        }
    }
}

// MARK: - Watch App Settings (Designer)

/// The action enum mirrors the watch's WatchAction (kept inline so the iOS
/// target doesn't need to import the Watch target).
enum DesignerWatchAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case loopMode
    case speed
    case sleepTimer
    case bookmark
    case empty

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .playPause:     return "playpause.fill"
        case .skipForward:   return "goforward.30"
        case .skipBackward:  return "gobackward.30"
        case .nextTrack:     return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .loopMode:      return "infinity"
        case .speed:         return "gauge.medium"
        case .sleepTimer:    return "moon.zzz.fill"
        case .bookmark:      return "bookmark.fill"
        case .empty:         return "plus"
        }
    }
}

struct WatchAppSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("crownAction") private var crownAction: String = "volume"
    @AppStorage("crownVolumeSensitivity") private var volumeSensitivity: Double = 0.05
    @AppStorage("crownScrubSensitivity") private var scrubSensitivity: Double = 0.5
    @AppStorage("watchPage1") private var page1Raw: String = "empty,empty,skipBackward,playPause,skipForward"
    @AppStorage("watchPage2") private var page2Raw: String = "loopMode,empty,speed,sleepTimer,bookmark"

    @State private var page1Slots: [DesignerWatchAction] = Array(repeating: .empty, count: 5)
    @State private var page2Slots: [DesignerWatchAction] = Array(repeating: .empty, count: 5)
    @State private var selectedPage: Int = 0

    private let palette: [DesignerWatchAction] = [
        .playPause, .skipForward, .skipBackward, .nextTrack,
        .previousTrack, .loopMode, .speed, .sleepTimer, .bookmark
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: Digital Crown Control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Digital Crown Control")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Picker("Digital Crown", selection: $crownAction) {
                        Text("Volume").tag("volume")
                        Text("Scrubbing").tag("scrub")
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                    )
                    .onChange(of: crownAction) { _, _ in
                        model.syncToWatch()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume Sensitivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $volumeSensitivity, in: 0.01...0.1, step: 0.01)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(volumeSensitivity, specifier: "%.2f")×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scrubbing Sensitivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundStyle(.secondary)
                            Slider(value: $scrubSensitivity, in: 0.1...1.0, step: 0.1)
                            Image(systemName: "hare")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(scrubSensitivity, specifier: "%.1f")×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // MARK: Watch App Designer
                VStack(alignment: .leading, spacing: 12) {
                    Text("Watch App Designer")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 16) {
                        Picker("Page", selection: $selectedPage) {
                            Text("Page 1").tag(0)
                            Text("Page 2").tag(1)
                        }
                        .pickerStyle(.segmented)

                        WatchPreviewCanvas(
                            slots: selectedPage == 0 ? $page1Slots : $page2Slots,
                            onChange: saveSlots
                        )
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.quaternary)
                    )
                }

                // MARK: Available Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Actions (Drag to slots)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(palette) { action in
                                PaletteItem(action: action)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )

                // MARK: Force Sync
                Button {
                    saveSlots()
                    model.syncToWatch()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text("Force Sync to Watch")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("Watch App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSlots() }
    }

    private func loadSlots() {
        page1Slots = padded(parse(page1Raw))
        page2Slots = padded(parse(page2Raw))
    }

    private func saveSlots() {
        page1Raw = page1Slots.map { $0.rawValue }.joined(separator: ",")
        page2Raw = page2Slots.map { $0.rawValue }.joined(separator: ",")
        model.syncToWatch()
    }

    private func parse(_ raw: String) -> [DesignerWatchAction] {
        raw.split(separator: ",").compactMap { DesignerWatchAction(rawValue: String($0)) }
    }

    private func padded(_ s: [DesignerWatchAction]) -> [DesignerWatchAction] {
        var out = s
        while out.count < 5 { out.append(.empty) }
        return Array(out.prefix(5))
    }
}

// A draggable palette chip showing the action icon + label.
private struct PaletteItem: View {
    let action: DesignerWatchAction

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: action.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text(action.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 78)
        .onDrag {
            NSItemProvider(object: NSString(string: action.rawValue))
        }
    }
}

// Faux Apple Watch frame that previews the live layout. This view is laid out
// to match the breathing room of the real watch UI: top-left + top-right
// slots are anchored to the very top, with the artwork-and-title block
// vertically centered and a 3-button transport row at the bottom.
private struct WatchPreviewCanvas: View {
    @Binding var slots: [DesignerWatchAction]
    var onChange: () -> Void

    var body: some View {
        ZStack {
            // Watch bezel
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .fill(Color.black)
                )

            VStack(spacing: 8) {
                // Artwork (real app icon)
                AppIconThumbnail(size: 64)
                    .padding(.top, 4)

                Text("Chapter 1")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.horizontal, 8)

                HStack(spacing: 8) {
                    DropSlot(slot: $slots[2], shape: .squircle, onChange: onChange)
                    DropSlot(slot: $slots[3], shape: .circle,   onChange: onChange)
                    DropSlot(slot: $slots[4], shape: .squircle, onChange: onChange)
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 14)

            // Top-row slots — anchored to the top of the frame so they NEVER
            // crowd the title. This mirrors the watch's actual layout.
            VStack {
                HStack {
                    DropSlot(slot: $slots[0], shape: .topGlyph, onChange: onChange)
                        .padding(.leading, 12)
                    Spacer()
                    DropSlot(slot: $slots[1], shape: .topGlyph, onChange: onChange)
                        .padding(.trailing, 12)
                }
                .padding(.top, 12)
                Spacer()
            }
        }
        .frame(width: 220, height: 268)
    }
}

// MARK: - Drop slot

private struct DropSlot: View {
    enum SlotShape { case squircle, circle, topGlyph }

    @Binding var slot: DesignerWatchAction
    let shape: SlotShape
    var onChange: () -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: width, height: height)
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { string, _ in
                if let raw = string as? String,
                   let action = DesignerWatchAction(rawValue: raw) {
                    DispatchQueue.main.async {
                        slot = action
                        onChange()
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(role: .destructive) {
                slot = .empty
                onChange()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
        }
    }

    private var width: CGFloat {
        switch shape {
        case .squircle: return 46
        case .circle:   return 50
        case .topGlyph: return 28
        }
    }
    private var height: CGFloat { width }

    @ViewBuilder
    private var background: some View {
        switch shape {
        case .squircle:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(isTargeted ? 0.6 : 0.25), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(slot == .empty ? 0.05 : 0.12))
                )
        case .circle:
            Circle()
                .stroke(Color.white.opacity(isTargeted ? 0.6 : 0.25), lineWidth: 1)
                .background(
                    Circle()
                        .fill(Color.white.opacity(slot == .empty ? 0.05 : 0.12))
                )
        case .topGlyph:
            // Top icons in the real watch UI float free (no chip), so we keep
            // the background invisible unless a drop is being targeted.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isTargeted ? 0.6 : 0.0), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if slot == .empty {
            if shape == .topGlyph {
                EmptyView()
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        } else {
            Image(systemName: slot.iconName)
                .font(.system(size: shape == .topGlyph ? 16 : 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - App icon thumbnail (uses the real AppIcon)

private struct AppIconThumbnail: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let img = Self.loadAppIcon() {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                // Fallback: filled rounded square so it's never a black box.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private static func loadAppIcon() -> UIImage? {
        loadAppIconImage()
    }
}

private func loadAppIconImage() -> UIImage? {
    if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
       let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
       let files = primary["CFBundleIconFiles"] as? [String],
       let last = files.last,
       let img = UIImage(named: last) {
        return img
    }
    return UIImage(named: "AppIcon")
}

#Preview {
    ContentView()
}
