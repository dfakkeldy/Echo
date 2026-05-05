import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import UIKit
import QuickLookThumbnailing
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
    var loopModeOn: Bool = true
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

    // iOS 26: avoid UIScreen.main usage; set from SwiftUI environment.
    private var displayScale: CGFloat = 2.0

    func setDisplayScale(_ scale: CGFloat) {
        displayScale = scale
    }

    // Playback
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
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

    override init() {
        speed = 1.25
        super.init()
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
        handleMessage(message)
        replyHandler(["status": "ok"])
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleMessage(userInfo)
    }
    
    private func handleMessage(_ message: [String: Any]) {
        DispatchQueue.main.async {
            if let command = message["command"] as? String {
                switch command {
                case "play": self.play()
                case "pause": self.pause()
                case "next": self.nextTrack()
                case "previous": self.previousTrackOrRestart()
                case "skipBackward": self.skipBackward30()
                case "skipForward": self.skipForward30()
                case "seek":
                    if let fraction = message["fraction"] as? Double {
                        self.seek(toFraction: fraction)
                    }
                case "scrubDelta":
                    if let d = message["delta"] as? Double {
                        let current = self.player?.currentTime().seconds ?? 0
                        let duration = self.durationSeconds ?? 0
                        // Make scrubbing gentle: e.g. 15 seconds per unit of delta
                        let target = max(0, min(duration, current + (d * 15.0)))
                        self.seek(toSeconds: target)
                    }
                case "volumeDelta":
                    if let d = message["delta"] as? Double {
                        let currentVol = self.player?.volume ?? 1.0
                        let newVol = max(0, min(1, currentVol + Float(d * 0.05)))
                        self.player?.volume = newVol
                    }
                case "toggle": self.togglePlayPause()
                default: break
                }
            }
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
        
        var context: [String: Any] = [:]
        context["isPlaying"] = isPlaying
        context["progressFraction"] = progressFraction
        
        let title = chapters.count >= 2 ? (currentSubtitle.isEmpty ? "Chapter \((currentChapterIndex ?? 0) + 1)" : currentSubtitle) : currentTitle
        context["title"] = title
        
        let crownAction = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"
        context["crownAction"] = crownAction
        
        if let data = watchThumbnailData {
            context["thumbnailData"] = data
        }
        
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("Failed to sync to watch: \(error)")
        }
    }

    deinit {
        // `deinit` is not actor-isolated; keep cleanup synchronous.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
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
        guard let url = persistence.restoreBookmark() else { return }
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

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        // Check for rewind before playing
        if let pausedAt = pauseTimestamp {
            let pausedDuration = Date().timeIntervalSince(pausedAt)
            if UserDefaults.standard.bool(forKey: "isRewindEnabled"),
               pausedDuration >= Double(UserDefaults.standard.integer(forKey: "rewindPauseDuration")) {
                let rewindAmount = Double(UserDefaults.standard.integer(forKey: "rewindAmount"))
                if let player = player {
                    let current = player.currentTime().seconds
                    var target = max(0, current - rewindAmount)
                    
                    // Don't rewind past the start of the current chapter
                    if chapters.count >= 2, let idx = currentChapterIndex {
                        let c = chapters[idx]
                        if target < c.startSeconds {
                            target = c.startSeconds
                        }
                    }

                    isManualSeeking = true
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.isManualSeeking = false
                            self?.updateCurrentChapterFromPlayerTime()
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

        player?.volume = 1.0
        player?.defaultRate = speed
        player?.rate = speed
        isPlaying = true

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
        if let player = player {
            persistence.saveProgress(for: currentTitle, time: player.currentTime().seconds)
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

    func skipBackward30() {
        guard let player else { return }
        let current = player.currentTime().seconds
        let target = max(0, current - 30)
        isManualSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
    }

    func skipForward30() {
        guard let player else { return }
        let current = player.currentTime().seconds
        let duration = durationSeconds ?? 0
        let target = min(duration, current + 30)
        isManualSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
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

    private func stop() {
        player?.pause()
        isPlaying = false
        currentTitle = "No track selected"
        progressFraction = 0
        progressText = "--:--"
        elapsedText = "--:--"

        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player = nil

        stopCurrentFileSecurityScopeIfNeeded()
    }

    private func prepareToPlay(index: Int, autoplay: Bool) {
        guard tracks.indices.contains(index) else { return }

        // Save progress before changing track
        if let player = player {
            persistence.saveProgress(for: currentTitle, time: player.currentTime().seconds)
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
        } else {
            speed = 1.25
        }
        chapters = []
        currentChapterIndex = nil
        isSeekingForChapterBoundary = false
        isManualSeeking = false

        // Clean old observers
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver); self.timeObserver = nil }

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
                self?.updateProgressFromPlayer()
                self?.updateCurrentChapterFromPlayerTime()
                self?.enforceEnabledState()
                self?.applyChapterLoopIfNeeded()
            }
        }
    }
    
    private func enforceEnabledState() {
        guard !isManualSeeking else { return }
        if chapters.count >= 2 {
            if let idx = currentChapterIndex, !chapters[idx].isEnabled {
                if let nextIdx = findNextEnabledChapterIndex(after: idx) {
                    seekToChapter(at: nextIdx)
                } else if loopModeOn, let firstIdx = findNextEnabledChapterIndex(after: -1) {
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
            if loopModeOn {
                // If it hits the absolute end of the file, just loop the current (last) chapter.
                if let idx = currentChapterIndex {
                    let c = chapters[idx]
                    let targetSeconds = c.startSeconds + 0.05
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

        if loopModeOn {
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
            DispatchQueue.main.async { self?.nextTrack() }
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
        
        if chapters.count >= 2, let idx = currentChapterIndex {
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
                if let savedTime = persistence.getProgress(for: currentTitle),
                   savedTime > 0, savedTime < seconds {
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
        // Quick Look thumbnail for the selected file (often shows album art / document icon).
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 240),
            scale: displayScale,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.uiImage
            thumbnailImage = image
            
            // Pre-compute watch thumbnail data to avoid re-encoding on every sync
            let targetSize = CGSize(width: 60, height: 60)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let scaledImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            watchThumbnailData = scaledImage.jpegData(compressionQuality: 0.6)
            
            updateNowPlayingInfo(isPaused: !isPlaying)
            syncToWatch()
        } catch {
            thumbnailImage = nil
            watchThumbnailData = nil
            updateNowPlayingInfo(isPaused: !isPlaying)
            syncToWatch()
        }
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
        } else {
            chapters = []
            currentChapterIndex = nil
            currentSubtitle = ""
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
            if loopModeOn {
                // Loop the CURRENT chapter.
                isSeekingForChapterBoundary = true
                let targetSeconds = c.startSeconds + 0.05
                player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            } else {
                if let nextIdx = findNextEnabledChapterIndex(after: idx) {
                    let nextC = chapters[nextIdx]
                    // If the next chapter starts exactly where this one ends (or very close), just let it play naturally.
                    if abs(nextC.startSeconds - c.endSeconds) < 1.0 && nextIdx == idx + 1 {
                        // Do nothing! Let AVPlayer seamlessly continue into the next chapter.
                    } else {
                        // Skip disabled chapters or gaps.
                        isSeekingForChapterBoundary = true
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

    private func persistSelection(url: URL) {
        // Refresh security scope for the new selection.
        stopSelectionSecurityScopeIfNeeded()
        selectionSecurityScopeURL = url
        hasSelectionSecurityScopeAccess = url.startAccessingSecurityScopedResource()

        // Save security-scoped bookmark so it restores after relaunch.
        persistence.saveBookmark(url: url)
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

struct ContentView: View {
    @State private var model = PlayerModel()
    @AppStorage("isDarkMode") private var isDarkMode = true
    @State private var showingFolderPicker = false
    @State private var showingPlaylist = false
    @State private var showingSettings = false
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0.0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var model = model

        NavigationStack {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.chapters.count >= 2 ? (model.currentSubtitle.isEmpty ? "Chapter \(model.currentChapterIndex ?? 0 + 1)" : model.currentSubtitle) : model.currentTitle)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            if model.chapters.count >= 2 {
                Text("Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !model.tracks.isEmpty {
                Text("Track \(model.currentIndex + 1) of \(model.tracks.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(model.elapsedText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubFraction : model.progressFraction },
                        set: { newValue in scrubFraction = newValue }
                    ),
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
                
                Text(model.progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                
                Button {
                    if model.chapters.count >= 2 {
                        model.previousChapterOrRestart()
                    } else {
                        model.previousTrackOrRestart()
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                
                Spacer()

                Button {
                    model.skipBackward30()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                
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
                
                Spacer()
                
                Button {
                    model.skipForward30()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                
                Spacer()

                Button {
                    if model.chapters.count >= 2 {
                        model.nextChapter()
                    } else {
                        model.nextTrack()
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            
            // Custom Bottom Toolbar to avoid UIKitToolbar errors
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        model.loopModeOn.toggle()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Image(systemName: model.loopModeOn ? "infinity.circle.fill" : "infinity.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    
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
                            .font(.headline)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    
                    Spacer()
                    
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.title2)
                    }
                    
                    Spacer()
                    
                    Button {
                        showingPlaylist = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                    }
                    
                    Spacer()
                    
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // Use native bar material for background to match HIG natively without the UIKit warning
            .background(.bar)
        }
        .padding(.horizontal)
        .padding(.top)
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
    @AppStorage("isRewindEnabled") private var isRewindEnabled = false
    @AppStorage("rewindPauseDuration") private var rewindPauseDuration = 60 // 1 minute default
    @AppStorage("rewindAmount") private var rewindAmount = 15 // 15 seconds default
    @Environment(\.dismiss) private var dismiss

    @State private var localCrownAction: String = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Dark Mode", isOn: $isDarkMode)
                }
                Section(header: Text("Watch Settings")) {
                    Picker("Digital Crown", selection: $localCrownAction) {
                        Text("Volume Control").tag("volume")
                        Text("Scrubbing").tag("scrub")
                    }
                    .onChange(of: localCrownAction) { oldValue, newValue in
                        UserDefaults.standard.set(newValue, forKey: "crownAction")
                        model.syncToWatch()
                    }
                }
                Section(header: Text("Smart Rewind"), footer: Text("Automatically rewind playback after being paused for a specific duration.")) {
                    Toggle("Enable Smart Rewind", isOn: $isRewindEnabled)
                    if isRewindEnabled {
                        Stepper("Pause Duration: \(rewindPauseDuration)s", value: $rewindPauseDuration, in: 5...3600, step: 5)
                        Stepper("Rewind Amount: \(rewindAmount)s", value: $rewindAmount, in: 5...300, step: 5)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

struct PlaylistView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        } else {
            return "\(m)m"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.chapters.count >= 2 {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            model.toggleChapterEnabled(at: index)
                        } label: {
                            HStack {
                                Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                                Spacer()
                                Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                                    .font(.caption)
                            }
                            .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
                        }
                    }
                    .onMove { source, destination in
                        model.moveChapters(from: source, to: destination)
                    }
                } else {
                    ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            model.toggleTrackEnabled(at: index)
                        } label: {
                            HStack {
                                Text(track.title)
                            }
                            .foregroundStyle(track.isEnabled ? .primary : .tertiary)
                        }
                    }
                    .onMove { source, destination in
                        model.moveTracks(from: source, to: destination)
                    }
                }
            }
            .environment(\.editMode, $editMode)
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
        }
    }
}

// MARK: - Persistence helper

private struct Persistence {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "BookLoop.selection.bookmark"
    private let progressKey = "BookLoop.progress.dictionary"
    private let speedKey = "BookLoop.playback.speed.dictionary"
    private let lastTrackKey = "BookLoop.lastTrack.dictionary"
    
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

    func saveProgress(for title: String, time: Double) {
        var dict = defaults.dictionary(forKey: progressKey) as? [String: Double] ?? [:]
        dict[title] = time
        defaults.set(dict, forKey: progressKey)
    }

    func getProgress(for title: String) -> Double? {
        let dict = defaults.dictionary(forKey: progressKey) as? [String: Double] ?? [:]
        return dict[title]
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

#Preview {
    ContentView()
}
