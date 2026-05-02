import SwiftUI
import Observation
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import UIKit
import QuickLookThumbnailing

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
final class PlayerModel {
    struct Track: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
    }

    struct Chapter: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        let title: String?
        let startSeconds: Double
        let endSeconds: Double
    }

    // UI state
    var loopModeOn: Bool = true
    var speed: Float = 1.25 // default 1.25x (your requirement)

    private(set) var folderURL: URL?
    private(set) var tracks: [Track] = []
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

    // Chapters (for .m4b with chapter markers)
    private(set) var chapters: [Chapter] = []
    private(set) var currentChapterIndex: Int? = nil
    private var isSeekingForChapterLoop: Bool = false
    private var isManualSeeking: Bool = false

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

    deinit {
        // `deinit` is not actor-isolated; keep cleanup synchronous.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        endBackgroundTask()
        stopAllSecurityScope()
    }

    // MARK: Folder + track loading

    func loadFolder(_ url: URL) {
        stop() // stop current playback when selecting a new folder/file

        folderURL = url
        
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        
        if isDir.boolValue {
            tracks = loadTracks(from: url)
        } else {
            tracks = [Track(url: url, title: url.deletingPathExtension().lastPathComponent)]
        }
        
        currentIndex = 0

        if let first = tracks.first {
            currentTitle = first.title
            prepareToPlay(index: 0, autoplay: false)
        } else {
            currentTitle = "No .mp3/.m4a/.m4b files found"
            updateNowPlayingInfo(isPaused: true) // keep something stable in Now Playing
        }

        persistSelection(url: url)
    }

    func restoreLastSelectionIfPossible() {
        guard let url = persistence.restoreBookmark() else { return }
        loadFolder(url)
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
        let tracks: [Track] = urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard allowed.contains(ext) else { return nil }
            return Track(url: url, title: url.deletingPathExtension().lastPathComponent)
        }

        return tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Playback controls

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
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
        player?.playImmediately(atRate: speed)
        isPlaying = true

        updateNowPlayingInfo(isPaused: false)
    }

    func pause() {
        // CRUCIAL: do NOT deactivate AVAudioSession when paused.
        player?.pause()
        isPlaying = false

        // Battery-friendly: do NOT keep a background task running while paused.
        // (We still keep Now Playing metadata + playbackRate=0.0 so the UI stays stable.)
        endBackgroundTask()

        // CRUCIAL: keep Now Playing metadata, but mark paused + playbackRate = 0.0
        updateNowPlayingInfo(isPaused: true)
    }

    private func endBackgroundTask() {
        guard pauseBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pauseBackgroundTask)
        pauseBackgroundTask = .invalid
    }

    func nextTrack() {
        if chapters.count >= 2 {
            nextChapter()
            return
        }
        guard !tracks.isEmpty else { return }
        let newIndex = (currentIndex + 1) % tracks.count
        prepareToPlay(index: newIndex, autoplay: true)
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
                }
            }
            updateNowPlayingElapsedTime()
            updateProgressFromPlayer()
            return
        }

        let newIndex = (currentIndex - 1 + tracks.count) % tracks.count
        prepareToPlay(index: newIndex, autoplay: true)
    }

    func nextChapter() {
        guard chapters.count >= 2 else {
            nextTrack()
            return
        }
        guard let player else { return }

        let t = player.currentTime().seconds
        guard t.isFinite else { return }

        // Find the next chapter whose *start* is meaningfully after the current time.
        // This prevents "Next Chapter" from seeking back to 0 when metadata indices are odd.
        let epsilon = 0.5
        if let next = chapters.first(where: { $0.startSeconds > t + epsilon }) {
            seekToChapter(at: next.index)
        } else {
            // Already at or beyond the final chapter start.
            // Go to next track.
            guard !tracks.isEmpty else { return }
            let newIndex = (currentIndex + 1) % tracks.count
            prepareToPlay(index: newIndex, autoplay: true)
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

        // If we're more than 5s into the current chapter, restart it.
        if let current = currentChapterForTime(t), (t - current.startSeconds) > 5 {
            seekToChapter(at: current.index)
            return
        }

        // Otherwise go to previous chapter start (strictly before current time).
        let epsilon = 0.5
        if let prev = chapters.last(where: { $0.startSeconds < t - epsilon }) {
            seekToChapter(at: prev.index)
        } else {
            // We're at the beginning already.
            seekToChapter(at: chapters.first?.index ?? 0)
        }
    }

    func skipBackward30() {
        guard let player else { return }
        let current = player.currentTime().seconds
        let target = max(0, current - 30)
        isManualSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
            }
        }
        updateNowPlayingElapsedTime()
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
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

        currentIndex = index
        currentTitle = tracks[index].title
        currentSubtitle = ""
        chapters = []
        currentChapterIndex = nil
        isSeekingForChapterLoop = false
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

        applySpeedToCurrentItem()
        configureRemoteCommandsIfNeeded()
        attachObserversForCurrentItem()

        // Prime Now Playing metadata even before play (helps show stable controls)
        updateNowPlayingInfo(isPaused: true)
        updateProgressFromPlayer()

        // Load duration using modern async API (avoids iOS 16+ deprecation warnings).
        Task { [weak self] in
            guard let self else { return }
            await self.loadDurationForNowPlaying()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.generateThumbnail(for: trackURL)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.loadChaptersForCurrentItem()
        }

        if autoplay {
            // Loop mode requirement: pressing Next while loop is ON should start looping that new track.
            // That behavior is naturally satisfied by "play the new track" + our end-of-track loop logic.
            play()
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
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateNowPlayingElapsedTime()
                self?.updateProgressFromPlayer()
                self?.updateCurrentChapterFromPlayerTime()
                self?.applyChapterLoopIfNeeded()
            }
        }
    }

    private func handleTrackEnded() {
        guard let player else { return }
        if loopModeOn {
            // If this file has chapters, Loop Mode should loop the *current chapter*,
            // not necessarily the whole file.
            if chapters.count >= 2, let idx = currentChapterIndex {
                let c = chapters[idx]
                player.seek(to: CMTime(seconds: c.startSeconds, preferredTimescale: 600)) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if self.isPlaying {
                            self.applySpeedToCurrentItem()
                            self.player?.play()
                        } else {
                            self.updateNowPlayingInfo(isPaused: true)
                        }
                        self.updateNowPlayingElapsedTime()
                        self.updateProgressFromPlayer()
                    }
                }
                return
            }

            // Fallback: restart the whole track.
            player.seek(to: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isPlaying {
                        self.applySpeedToCurrentItem()
                        self.player?.play()
                    } else {
                        // Even if not playing, keep metadata stable + paused state
                        self.updateNowPlayingInfo(isPaused: true)
                    }
                    self.updateProgressFromPlayer()
                }
            }
        } else {
            // If loop mode is off, move forward
            nextTrack()
        }
    }

    private func applySpeedToCurrentItem() {
        // Keep the pitch-preserving algorithm even after loops/track changes.
        player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
        if isPlaying {
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
                progressFraction = frac
                let remaining = max(0, chapterDuration - chapterElapsed) / Double(speed)
                progressText = "-\(formatTime(remaining))"
                elapsedText = formatTime(max(0, chapterElapsed) / Double(speed))
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
        progressFraction = frac

        let remaining = max(0, duration - elapsed) / Double(speed)
        progressText = "-\(formatTime(remaining))"
        elapsedText = formatTime(max(0, elapsed) / Double(speed))
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
            thumbnailImage = representation.uiImage
            updateNowPlayingInfo(isPaused: !isPlaying)
        } catch {
            thumbnailImage = nil
            updateNowPlayingInfo(isPaused: !isPlaying)
        }
    }

    private func loadChaptersForCurrentItem() async {
        guard let asset = player?.currentItem?.asset else { return }

        // Only bother for common audiobook container types.
        let ext = tracks.indices.contains(currentIndex) ? tracks[currentIndex].url.pathExtension.lowercased() : ""
        guard ext == "m4b" || ext == "m4a" else { return }

        // Most audiobooks expose chapters via AVAsset timed chapter metadata groups.
        // This API is available broadly and avoids newer marker-group types that may not exist in all SDKs.
        let locales = asset.availableChapterLocales
        let groups: [AVTimedMetadataGroup]
        if let firstLocale = locales.first {
            groups = asset.chapterMetadataGroups(
                withTitleLocale: firstLocale,
                containingItemsWithCommonKeys: nil
            )
        } else {
            groups = asset.chapterMetadataGroups(
                withTitleLocale: Locale.current,
                containingItemsWithCommonKeys: nil
            )
        }

        var built: [Chapter] = []
        built.reserveCapacity(groups.count)

        for g in groups {
            let start = g.timeRange.start.seconds
            let end = (g.timeRange.start + g.timeRange.duration).seconds

            var title: String? = nil
            if let item = g.items.first(where: { $0.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue }) {
                title = item.stringValue
            } else if let item = g.items.first {
                title = item.stringValue
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

        // Some files return a single "chapter" spanning whole book; treat that as "no chapters".
        if built.count >= 2 {
            chapters = built
            updateCurrentChapterFromPlayerTime()
        } else {
            chapters = []
            currentChapterIndex = nil
            currentSubtitle = ""
            updateNowPlayingInfo(isPaused: !isPlaying)
        }
    }

    private func updateCurrentChapterFromPlayerTime() {
        guard chapters.count >= 2, let player else { return }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }

        // Find the last chapter where t >= startSeconds.
        // This avoids matching the previous chapter when t is exactly on the boundary.
        if let idx = chapters.lastIndex(where: { t >= $0.startSeconds }) {
            if currentChapterIndex != idx {
                currentChapterIndex = idx
                let c = chapters[idx]
                if let title = c.title, !title.isEmpty {
                    currentSubtitle = "Chapter \(idx + 1): \(title)"
                } else {
                    currentSubtitle = "Chapter \(idx + 1)"
                }
                updateNowPlayingInfo(isPaused: !isPlaying)
            }
        }
    }

    private func currentChapterForTime(_ t: Double) -> Chapter? {
        guard chapters.count >= 2 else { return nil }
        return chapters.last(where: { t >= $0.startSeconds })
    }

    private func applyChapterLoopIfNeeded() {
        guard !isManualSeeking else { return }
        guard loopModeOn, chapters.count >= 2, let idx = currentChapterIndex, let player else { return }
        guard !isSeekingForChapterLoop else { return }

        let t = player.currentTime().seconds
        guard t.isFinite else { return }

        let c = chapters[idx]
        // Be forgiving: with a 1s observer tick and speeds > 1.0, we can jump past the boundary.
        // Use a wider window to reliably catch the chapter end.
        if t >= (c.endSeconds - 1.5) {
            isSeekingForChapterLoop = true
            player.seek(to: CMTime(seconds: c.startSeconds, preferredTimescale: 600)) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSeekingForChapterLoop = false
                    if self.isPlaying {
                        self.applySpeedToCurrentItem()
                        self.player?.play()
                    }
                    self.updateNowPlayingElapsedTime()
                    self.updateProgressFromPlayer()
                }
            }
        }
    }

    private func seekToChapter(at index: Int) {
        guard chapters.indices.contains(index), let player else { return }
        let c = chapters[index]
        
        // Seek slightly past the boundary to avoid rounding errors matching the previous chapter
        let targetSeconds = c.startSeconds + 0.05
        
        isManualSeeking = true
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isManualSeeking = false
                self?.updateCurrentChapterFromPlayerTime()
                self?.updateNowPlayingElapsedTime()
                self?.updateProgressFromPlayer()
                if self?.isPlaying == true {
                    self?.applySpeedToCurrentItem()
                    self?.player?.play()
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
    @State private var showingFolderPicker = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .center, spacing: 12) {
                if let image = model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 220, height: 220)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
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

            HStack(spacing: 12) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play",
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.skipBackward30()
                } label: {
                    Label("Back 30s", systemImage: "gobackward.30")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                Toggle("Loop Mode", isOn: $model.loopModeOn)
                    .toggleStyle(.switch)

                Spacer(minLength: 12)

                Picker("Speed", selection: Binding(
                    get: { model.speed },
                    set: { model.setSpeed($0) }
                )) {
                    Text("1x").tag(Float(1.0))
                    Text("1.25x").tag(Float(1.25))
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack(spacing: 12) {
                Text(model.elapsedText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: model.progressFraction)
                    .frame(maxWidth: .infinity)
                Text(model.progressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button {
                    // If this file has chapters, Previous behaves like "Previous Chapter"
                    // (restart chapter if you're >5s in).
                    if model.chapters.count >= 2 {
                        model.previousChapterOrRestart()
                    } else {
                        model.previousTrackOrRestart()
                    }
                } label: {
                    Label(model.chapters.count >= 2 ? "Prev Chapter" : "Previous", systemImage: "backward.end.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    if model.chapters.count >= 2 {
                        model.nextChapter()
                    } else {
                        model.nextTrack()
                    }
                } label: {
                    Label(model.chapters.count >= 2 ? "Next Chapter" : "Next", systemImage: "forward.end.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Select Folder or File", systemImage: "folder")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if !model.tracks.isEmpty {
                Text("Tracks: \(model.tracks.count)  •  Current: \(model.currentIndex + 1)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if model.chapters.count >= 2 {
                Text("Chapters: \(model.chapters.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.loadFolder(url)
            }
        }
        .onAppear {
            // Configure remote commands early so the Watch/Now Playing UI is stable once audio starts.
            // (The model also guards to configure only once.)
            model.setSpeed(1.25) // ensure default speed is applied everywhere
            model.setDisplayScale(displayScale)
            model.restoreLastSelectionIfPossible()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Persistence helper

private struct Persistence {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "BookLoop.selection.bookmark"

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
