import Foundation
import AVFoundation
import Observation

// MARK: - PlaybackControllerDelegate

protocol PlaybackControllerDelegate: AnyObject {
    func playbackController(_ controller: PlaybackController, didUpdateTime currentTime: TimeInterval)
    func playbackControllerDidPlayToEnd(_ controller: PlaybackController)
    func playbackControllerInterruptionBegan(_ controller: PlaybackController)
    func playbackControllerInterruptionEnded(_ controller: PlaybackController, shouldResume: Bool)
}

// MARK: - PlaybackController

@Observable
final class PlaybackController {
    let audioEngine = AudioEngine()
    let state = PlaybackState()
    weak var delegate: PlaybackControllerDelegate?

    var speed: Float = 1.25
    var loopMode: LoopMode = .off
    var isVolumeBoostEnabled: Bool = false

    var isPlaying: Bool { audioEngine.isPlaying }
    var currentTime: TimeInterval { audioEngine.currentTime }
    var duration: TimeInterval? { audioEngine.duration }

    // Coordinators — set by PlayerModel to handle cross-cutting concerns.
    @ObservationIgnored var coordinator_smartRewind: ((_ pausedDuration: TimeInterval) -> Double)?
    @ObservationIgnored var coordinator_jumpToChapterStartForHours: ((_ pausedDuration: TimeInterval) -> Bool)?
    @ObservationIgnored var coordinator_loadTrack: ((_ index: Int, _ autoplay: Bool) -> Void)?
    @ObservationIgnored var coordinator_persistAndSync: ((_ isPaused: Bool) -> Void)?
    @ObservationIgnored var coordinator_checkVoiceMemo: ((_ at: Double, _ previous: Double?) -> Void)?
    @ObservationIgnored var coordinator_seekCompleted: ((_ isManual: Bool) -> Void)?
    @ObservationIgnored var coordinator_persistSpeed: ((_ key: String, _ speed: Float) -> Void)?
    @ObservationIgnored var coordinator_persistLoopMode: ((_ key: String, _ mode: String) -> Void)?
    @ObservationIgnored var coordinator_hasBookmarks: (() -> Bool)?
    @ObservationIgnored var coordinator_refreshProgress: (() -> Void)?
    @ObservationIgnored var coordinator_enabledBookmarks: (() -> [Bookmark])?
    @ObservationIgnored var coordinator_jumpToBookmark: ((Bookmark) -> Void)?
    @ObservationIgnored var coordinator_refreshArtwork: ((TimeInterval, Bool) -> Void)?
    @ObservationIgnored var coordinator_endBackgroundTask: (() -> Void)?
    @ObservationIgnored var coordinator_saveProgress: ((_ folder: String, _ trackId: String, _ time: TimeInterval) -> Void)?
    @ObservationIgnored var coordinator_stopSecurityScope: (() -> Void)?
    @ObservationIgnored var coordinator_handleChapterEndSleepTimer: (() -> Bool)?
    @ObservationIgnored var coordinator_currentTrackBookmarks: (() -> [Bookmark])?
    @ObservationIgnored var coordinator_isRewindEnabled: (() -> Bool)?
    @ObservationIgnored var coordinator_configureAudioSession: (() -> Void)?
    @ObservationIgnored var coordinator_startSecurityScope: (() -> Void)?
    @ObservationIgnored var coordinator_playStateChanged: ((_ isPlaying: Bool) -> Void)?

    init() {
        audioEngine.delegate = self
    }

    // MARK: - Pure Helpers

    func findNextEnabledTrackIndex(in tracks: [Track], currentIndex: Int) -> Int? {
        guard !tracks.isEmpty else { return nil }
        for i in (currentIndex + 1)..<tracks.count {
            if tracks[i].isEnabled { return i }
        }
        return nil
    }

    /// Jumps to the next enabled chapter or track when the current one is disabled.
    /// Called on each time update tick from the delegate.
    func enforceEnabledState() {
        guard !state.isManualSeeking else { return }
        if state.chapters.count >= 2 {
            if let idx = state.currentChapterIndex, !state.chapters[idx].isEnabled {
                if let nextIdx = ChapterService.nextEnabledIndex(after: idx, in: state.chapters) {
                    seekToChapter(at: nextIdx)
                } else if loopMode == .chapter, let firstIdx = ChapterService.nextEnabledIndex(after: -1, in: state.chapters) {
                    seekToChapter(at: firstIdx)
                } else {
                    nextTrack()
                }
            }
        } else {
            if state.tracks.indices.contains(state.currentIndex), !state.tracks[state.currentIndex].isEnabled {
                nextTrack()
            }
        }
    }

    func findPrevEnabledTrackIndex(in tracks: [Track], currentIndex: Int) -> Int? {
        guard !tracks.isEmpty else { return nil }
        for i in stride(from: currentIndex - 1, through: 0, by: -1) {
            if tracks[i].isEnabled { return i }
        }
        return nil
    }

    func applySpeedToCurrentItem() {
        audioEngine.setSpeed(speed)
        if isPlaying {
            audioEngine.playImmediately(atRate: speed)
        }
    }

    // MARK: - Playback Commands

    func play() {
        if let pausedAt = state.pauseTimestamp {
            let pausedDuration = Date().timeIntervalSince(pausedAt)
            if coordinator_isRewindEnabled?() ?? false {
                if audioEngine.isItemLoaded {
                    let current = audioEngine.currentTime
                    let rewindAmount = coordinator_smartRewind?(pausedDuration) ?? 0
                    var target = current

                    if coordinator_jumpToChapterStartForHours?(pausedDuration) == true,
                       state.chapters.count >= 2,
                       let idx = state.currentChapterIndex {
                        target = state.chapters[idx].startSeconds
                    } else if rewindAmount > 0 {
                        target = max(0, current - rewindAmount)

                        if state.chapters.count >= 2, let idx = state.currentChapterIndex {
                            let c = state.chapters[idx]
                            if target < c.startSeconds {
                                target = c.startSeconds
                            }
                        }
                    }

                    if target != current {
                        state.isManualSeeking = true
                        audioEngine.seek(to: target) { [weak self] _ in
                            DispatchQueue.main.async {
                                self?.state.isManualSeeking = false
                                self?.coordinator_seekCompleted?(false)
                            }
                        }
                    }
                }
            }
            state.pauseTimestamp = nil
        }

        coordinator_endBackgroundTask?()

        guard !state.tracks.isEmpty else { return }
        coordinator_configureAudioSession?()

        if !audioEngine.isItemLoaded {
            coordinator_loadTrack?(state.currentIndex, false)
        }
        coordinator_startSecurityScope?()

        applySpeedToCurrentItem()

        audioEngine.playImmediately(atRate: speed)
        state.isPlaying = true
        let currentSecond = audioEngine.currentTime
        if currentSecond.isFinite {
            coordinator_checkVoiceMemo?(currentSecond, nil)
        }

        coordinator_persistAndSync?(false)
        coordinator_playStateChanged?(true)
    }

    func pause() {
        audioEngine.pause()
        state.isPlaying = false

        if state.pauseTimestamp == nil {
            state.pauseTimestamp = Date()
        }

        coordinator_endBackgroundTask?()
        coordinator_persistAndSync?(true)
        coordinator_playStateChanged?(false)

        if audioEngine.isItemLoaded,
           let folder = state.folderURL?.absoluteString,
           state.tracks.indices.contains(state.currentIndex) {
            coordinator_saveProgress?(folder, state.tracks[state.currentIndex].id, audioEngine.currentTime)
        }
    }

    func togglePlayPause() {
        if audioEngine.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        audioEngine.seek(to: time, completion: completion)
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        applySpeedToCurrentItem()
        if let key = state.folderURL?.absoluteString {
            coordinator_persistSpeed?(key, speed)
        }
        coordinator_persistAndSync?(!audioEngine.isPlaying)
    }

    func setVolumeBoost(enabled: Bool) {
        isVolumeBoostEnabled = enabled
        audioEngine.setVolumeBoost(enabled: enabled)
    }

    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
        if let key = state.folderURL?.absoluteString {
            coordinator_persistLoopMode?(key, mode.rawValue)
        }
        coordinator_persistAndSync?(!audioEngine.isPlaying)
    }

    func cycleLoopMode() {
        let hasBookmarks = coordinator_hasBookmarks?() ?? false
        switch loopMode {
        case .off:
            setLoopMode(.chapter)
        case .chapter:
            setLoopMode(hasBookmarks ? .bookmark : .off)
        case .bookmark:
            setLoopMode(.off)
        }
    }

    func stop() {
        state.isPlaying = false
        state.currentTitle = String(localized: "No track selected")
        state.progressFraction = 0
        state.progressText = "--:--"
        state.elapsedText = "--:--"

        audioEngine.stop()
        coordinator_stopSecurityScope?()
    }

    func replaceCurrentItem(with url: URL, startTime: TimeInterval? = nil) {
        audioEngine.replaceCurrentItem(with: url, startTime: startTime)
    }

    // MARK: - Navigation

    func nextTrack() {
        if state.chapters.count >= 2 {
            nextChapter()
            return
        }
        if let newIndex = findNextEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex) {
            coordinator_loadTrack?(newIndex, true)
        } else if let firstEnabled = state.tracks.firstIndex(where: { $0.isEnabled }) {
            coordinator_loadTrack?(firstEnabled, true)
        }
    }

    func previousTrackOrRestart() {
        if state.chapters.count >= 2 {
            previousChapterOrRestart()
            return
        }
        guard !state.tracks.isEmpty else { return }
        let elapsed = audioEngine.currentTime
        if elapsed.isFinite, elapsed > 5 {
            state.isManualSeeking = true
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.state.isManualSeeking = false
                    self?.coordinator_seekCompleted?(false)
                }
            }
            coordinator_refreshProgress?()
            return
        }

        if let newIndex = findPrevEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex) {
            coordinator_loadTrack?(newIndex, true)
        } else {
            state.isManualSeeking = true
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.state.isManualSeeking = false
                    self?.coordinator_seekCompleted?(false)
                }
            }
        }
    }

    func nextChapter() {
        guard state.chapters.count >= 2 else {
            nextTrack()
            return
        }
        let currentIdx = state.currentChapterIndex ?? -1
        if let nextIdx = ChapterService.nextEnabledIndex(after: currentIdx, in: state.chapters) {
            seekToChapter(at: nextIdx)
        } else if let newIndex = findNextEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex) {
            coordinator_loadTrack?(newIndex, true)
        } else if let firstEnabled = state.tracks.firstIndex(where: { $0.isEnabled }) {
            coordinator_loadTrack?(firstEnabled, true)
        }
    }

    func previousChapterOrRestart() {
        guard state.chapters.count >= 2 else {
            previousTrackOrRestart()
            return
        }
        guard audioEngine.isItemLoaded else { return }

        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        if let _ = state.currentChapterIndex, let current = currentChapterForTime(t), (t - current.startSeconds) > 5 {
            seekToChapter(at: current.index)
            return
        }

        let currentIdx = state.currentChapterIndex ?? 0
        if let prevIdx = ChapterService.prevEnabledIndex(before: currentIdx, in: state.chapters) {
            seekToChapter(at: prevIdx)
        } else if let firstEnabled = ChapterService.nextEnabledIndex(after: -1, in: state.chapters) {
            seekToChapter(at: firstEnabled)
        } else {
            seekToChapter(at: state.chapters.first?.index ?? 0)
        }
    }

    func seekToChapter(at index: Int) {
        guard state.chapters.indices.contains(index), audioEngine.isItemLoaded else { return }
        let c = state.chapters[index]
        let targetSeconds = c.startSeconds + 0.05

        state.isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.isManualSeeking = false
                self.coordinator_seekCompleted?(false)
                self.coordinator_refreshProgress?()
                if self.state.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                }
            }
        }
    }

    func resumeAfterSeek() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.isSeekingForChapterBoundary = false
            if self.state.isPlaying {
                self.audioEngine.playImmediately(atRate: self.speed)
                self.applySpeedToCurrentItem()
            } else {
                self.coordinator_persistAndSync?(true)
            }
            self.coordinator_refreshProgress?()
            self.coordinator_seekCompleted?(false)
        }
    }

    private func currentChapterForTime(_ t: Double) -> Chapter? {
        ChapterService.chapter(forTime: t, in: state.chapters)
    }

    // MARK: - Skip & Seek

    @discardableResult
    func skipBackwardNavigation() -> Bool {
        if loopMode == .bookmark,
           audioEngine.currentTime.isFinite,
           jumpToPreviousBookmark(from: audioEngine.currentTime) {
            return true
        }

        if state.chapters.count >= 2 {
            previousChapterOrRestart()
        } else {
            previousTrackOrRestart()
        }
        return false
    }

    @discardableResult
    func skipForwardNavigation() -> Bool {
        if loopMode == .bookmark,
           audioEngine.currentTime.isFinite,
           jumpToNextBookmark(from: audioEngine.currentTime) {
            return true
        }

        if state.chapters.count >= 2 {
            nextChapter()
        } else {
            nextTrack()
        }
        return false
    }

    @discardableResult
    func skipBackward30() -> Bool {
        guard audioEngine.isItemLoaded else { return false }
        let current = audioEngine.currentTime
        guard current.isFinite else { return false }

        if loopMode == .bookmark {
            if jumpToPreviousBookmark(from: current) {
                return true
            }
            if state.chapters.count >= 2 {
                previousChapterOrRestart()
            } else {
                previousTrackOrRestart()
            }
            return false
        }

        let target = max(0, current - 30)
        state.isManualSeeking = true
        audioEngine.seek(to: target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.state.isManualSeeking = false
                self?.coordinator_seekCompleted?(false)
            }
        }
        coordinator_refreshProgress?()
        return false
    }

    @discardableResult
    func skipForward30() -> Bool {
        guard audioEngine.isItemLoaded else { return false }
        let current = audioEngine.currentTime
        guard current.isFinite else { return false }

        if loopMode == .bookmark {
            if jumpToNextBookmark(from: current) {
                return true
            }
            if state.chapters.count >= 2 {
                nextChapter()
            } else {
                nextTrack()
            }
            return false
        }

        let duration = state.durationSeconds ?? 0
        let target = min(duration, current + 30)
        state.isManualSeeking = true
        audioEngine.seek(to: target) { [weak self] _ in
            DispatchQueue.main.async {
                self?.state.isManualSeeking = false
                self?.coordinator_seekCompleted?(false)
            }
        }
        coordinator_refreshProgress?()
        return false
    }

    func seek(toSeconds targetSeconds: Double) {
        guard audioEngine.isItemLoaded else { return }
        state.isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.isManualSeeking = false
                self.coordinator_seekCompleted?(false)
                self.coordinator_refreshProgress?()
                self.coordinator_refreshArtwork?(targetSeconds, true)
                if self.state.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                }
            }
        }
    }

    func seek(toFraction fraction: Double) {
        let safeFraction = min(1, max(0, fraction))

        if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            let c = state.chapters[idx]
            let chapterDuration = c.endSeconds - c.startSeconds
            if chapterDuration > 0 {
                let targetSeconds = c.startSeconds + (chapterDuration * safeFraction)
                seek(toSeconds: targetSeconds)
            }
        } else {
            let duration = state.durationSeconds ?? 0
            if duration > 0 {
                let targetSeconds = duration * safeFraction
                seek(toSeconds: targetSeconds)
            }
        }
    }

    // MARK: - Bookmark Jump

    private func jumpToNextBookmark(from currentTime: Double) -> Bool {
        let bookmarks = coordinator_enabledBookmarks?() ?? []
        guard let target = bookmarks.first(where: { $0.timestamp > currentTime + 1.0 }) ?? bookmarks.first else {
            return false
        }
        coordinator_jumpToBookmark?(target)
        return true
    }

    private func jumpToPreviousBookmark(from currentTime: Double) -> Bool {
        let bookmarks = coordinator_enabledBookmarks?() ?? []
        guard let target = bookmarks.last(where: { $0.timestamp < currentTime - 2.0 }) ?? bookmarks.last else {
            return false
        }
        coordinator_jumpToBookmark?(target)
        return true
    }

    // MARK: - Loop Enforcement

    func applyChapterLoopIfNeeded() {
        guard !state.isManualSeeking else { return }
        guard state.chapters.count >= 2, let idx = state.currentChapterIndex, audioEngine.isItemLoaded else { return }
        guard !state.isSeekingForChapterBoundary else { return }

        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        let c = state.chapters[idx]
        if t >= (c.endSeconds - 0.5) {
            if coordinator_handleChapterEndSleepTimer?() == true {
                return
            }
            if loopMode == .chapter {
                state.isSeekingForChapterBoundary = true
                state.progressFraction = 0
                let targetSeconds = c.startSeconds + 0.05
                audioEngine.seek(to: targetSeconds) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            } else {
                if let nextIdx = ChapterService.nextEnabledIndex(after: idx, in: state.chapters) {
                    let nextC = state.chapters[nextIdx]
                    if abs(nextC.startSeconds - c.endSeconds) < 1.0 && nextIdx == idx + 1 {
                        // Contiguous chapters — let AVPlayer seamlessly continue.
                    } else {
                        state.isSeekingForChapterBoundary = true
                        state.progressFraction = 0
                        audioEngine.seek(to: nextC.startSeconds) { [weak self] _ in
                            self?.resumeAfterSeek()
                        }
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.state.isSeekingForChapterBoundary = false
                        self?.nextTrack()
                    }
                }
            }
        }
    }

    func applyBookmarkLoopIfNeeded() {
        guard loopMode == .bookmark, !state.isManualSeeking, !state.isSeekingForChapterBoundary else { return }
        guard audioEngine.isItemLoaded else { return }
        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        let sorted = (coordinator_currentTrackBookmarks?() ?? []).filter { $0.isEnabled }
        guard sorted.count >= 2 else { return }

        guard let startIdx = sorted.lastIndex(where: { $0.timestamp < t }) else { return }
        let endIdx = startIdx + 1
        guard endIdx < sorted.count else {
            if sorted.count >= 2, t - sorted[sorted.count - 1].timestamp < 1.0 {
                let lastSegmentStart = sorted.count - 2
                state.isSeekingForChapterBoundary = true
                audioEngine.seek(to: sorted[lastSegmentStart].timestamp + 0.05) { [weak self] _ in
                    self?.resumeAfterSeek()
                }
            }
            return
        }

        let lookAhead = max(0.5, 0.3 * Double(speed))
        if t >= sorted[endIdx].timestamp - lookAhead {
            state.isSeekingForChapterBoundary = true
            audioEngine.seek(to: sorted[startIdx].timestamp + 0.05) { [weak self] _ in
                self?.resumeAfterSeek()
            }
        }
    }

    // MARK: - Track End Handling

    func handleTrackEnded() {
        guard audioEngine.isItemLoaded else { return }

        if coordinator_handleChapterEndSleepTimer?() == true { return }

        if state.chapters.count >= 2 {
            if loopMode == .chapter {
                if let idx = state.currentChapterIndex {
                    let targetSeconds = state.chapters[idx].startSeconds + 0.05
                    state.progressFraction = 0
                    audioEngine.seek(to: targetSeconds) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if self.isPlaying {
                                self.audioEngine.playImmediately(atRate: self.speed)
                                self.applySpeedToCurrentItem()
                            } else {
                                self.coordinator_persistAndSync?(true)
                            }
                            self.coordinator_refreshProgress?()
                        }
                    }
                    return
                }
            }
            nextTrack()
            return
        }

        if loopMode == .chapter {
            state.progressFraction = 0
            audioEngine.seek(to: 0) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isPlaying {
                        self.audioEngine.playImmediately(atRate: self.speed)
                        self.applySpeedToCurrentItem()
                    } else {
                        self.coordinator_persistAndSync?(true)
                    }
                    self.coordinator_refreshProgress?()
                }
            }
        } else {
            nextTrack()
        }
    }
}

// MARK: - AudioEngineDelegate

extension PlaybackController: AudioEngineDelegate {
    func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval) {
        delegate?.playbackController(self, didUpdateTime: currentTime)
    }

    func audioEngineDidPlayToEnd(_ engine: AudioEngine) {
        delegate?.playbackControllerDidPlayToEnd(self)
    }

    func audioEngineInterruptionBegan(_ engine: AudioEngine) {
        delegate?.playbackControllerInterruptionBegan(self)
    }

    func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool) {
        delegate?.playbackControllerInterruptionEnded(self, shouldResume: shouldResume)
    }
}
