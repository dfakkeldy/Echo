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

@MainActor @Observable
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
    @ObservationIgnored var coordinator_seekBackwardDuration: (() -> Double)?
    @ObservationIgnored var coordinator_seekForwardDuration: (() -> Double)?

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
        // Apply smart rewind if resuming after a pause.
        applySmartRewindIfNeeded()
        state.pauseTimestamp = nil

        coordinator_endBackgroundTask?()

        guard !state.tracks.isEmpty else { return }

        assert(coordinator_configureAudioSession != nil,
               "coordinator_configureAudioSession must be wired — audio session setup required for playback")
        coordinator_configureAudioSession?()

        if !audioEngine.isItemLoaded {
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — track loading required for playback")
            coordinator_loadTrack?(state.currentIndex, false)
        }
        coordinator_startSecurityScope?()

        applySpeedToCurrentItem()

        // Set Now Playing metadata *before* starting the audio engine.
        // The engine starts a repeating Timer on playImmediately; if the first
        // tick fires before MPNowPlayingInfoCenter has playbackRate set, the
        // Lock Screen may show the wrong transport button.
        state.isPlaying = true
        coordinator_persistAndSync?(false)
        coordinator_playStateChanged?(true)

        audioEngine.playImmediately(atRate: speed)
        if audioEngine.currentTime.isFinite {
            coordinator_checkVoiceMemo?(audioEngine.currentTime, nil)
        }
    }

    /// Computes and applies the smart rewind target based on pause duration.
    /// Handles chapter-start jumps and chapter-boundary clamping for multi-M4B books.
    private func applySmartRewindIfNeeded() {
        guard let pausedAt = state.pauseTimestamp else { return }
        let pausedDuration = Date().timeIntervalSince(pausedAt)

        guard coordinator_isRewindEnabled?() ?? false, audioEngine.isItemLoaded else { return }

        let current = audioEngine.currentTime
        let rewindAmount = coordinator_smartRewind?(pausedDuration) ?? 0
        let target = computeRewindTarget(current: current, pausedDuration: pausedDuration, rewindAmount: rewindAmount)

        guard target != current else { return }

        state.isManualSeeking = true
        audioEngine.seek(to: target) { [weak self] _ in
            self?.state.isManualSeeking = false
            self?.coordinator_seekCompleted?(false)
        }
    }

    /// Determines the rewind target time, clamping to chapter boundaries when appropriate.
    private func computeRewindTarget(current: TimeInterval, pausedDuration: TimeInterval, rewindAmount: TimeInterval) -> TimeInterval {
        if coordinator_jumpToChapterStartForHours?(pausedDuration) == true {
            return computeChapterStartTarget(current: current)
        } else if rewindAmount > 0 {
            var target = max(0, current - rewindAmount)
            target = clampToChapterBoundary(target: target, current: current)
            return target
        }
        return current
    }

    private func computeChapterStartTarget(current: TimeInterval) -> TimeInterval {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            let currentOffset = state.m4bBooks.indices.contains(state.currentIndex) ? state.m4bBooks[state.currentIndex].cumulativeStartOffset : 0
            let globalTime = currentOffset + current
            if let idx = aggregatedChapterIndex(at: globalTime) {
                return max(0, state.aggregatedChapters[idx].startSeconds - currentOffset)
            }
        } else if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            return state.chapters[idx].startSeconds
        }
        return 0
    }

    /// Clamps the rewind target to the current chapter's start, preventing cross-chapter rewinds.
    private func clampToChapterBoundary(target: TimeInterval, current: TimeInterval) -> TimeInterval {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            let currentOffset = state.m4bBooks.indices.contains(state.currentIndex) ? state.m4bBooks[state.currentIndex].cumulativeStartOffset : 0
            let globalTime = currentOffset + current
            if let idx = aggregatedChapterIndex(at: globalTime) {
                let intraBookStart = max(0, state.aggregatedChapters[idx].startSeconds - currentOffset)
                return max(target, intraBookStart)
            }
        } else if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            return max(target, state.chapters[idx].startSeconds)
        }
        return target
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

    func setVolumeBoost(enabled: Bool, gainDB: Float = 9.0) {
        isVolumeBoostEnabled = enabled
        audioEngine.setVolumeBoost(enabled: enabled, gainDB: gainDB)
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
        assert(coordinator_stopSecurityScope != nil,
               "coordinator_stopSecurityScope must be wired — security-scoped resource cleanup required")
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
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — track navigation required")
            coordinator_loadTrack?(newIndex, true)
        } else if let firstEnabled = state.tracks.firstIndex(where: { $0.isEnabled }) {
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — track navigation required")
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
                self?.state.isManualSeeking = false
                self?.coordinator_seekCompleted?(false)
            }
            coordinator_refreshProgress?()
            return
        }

        if let newIndex = findPrevEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex) {
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — track navigation required")
            coordinator_loadTrack?(newIndex, true)
        } else {
            state.isManualSeeking = true
            audioEngine.seek(to: 0) { [weak self] _ in
                self?.state.isManualSeeking = false
                self?.coordinator_seekCompleted?(false)
            }
        }
    }

    func nextChapter() {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            nextAggregatedChapter()
            return
        }
        guard state.chapters.count >= 2 else {
            nextTrack()
            return
        }
        let currentIdx = state.currentChapterIndex ?? -1
        if let nextIdx = ChapterService.nextEnabledIndex(after: currentIdx, in: state.chapters) {
            seekToChapter(at: nextIdx)
        } else if let newIndex = findNextEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex) {
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — chapter navigation fallback")
            coordinator_loadTrack?(newIndex, true)
        } else if let firstEnabled = state.tracks.firstIndex(where: { $0.isEnabled }) {
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — chapter navigation fallback")
            coordinator_loadTrack?(firstEnabled, true)
        }
    }

    private func nextAggregatedChapter() {
        let currentOffset: TimeInterval = {
            guard state.m4bBooks.indices.contains(state.currentIndex) else { return 0 }
            return state.m4bBooks[state.currentIndex].cumulativeStartOffset
        }()
        let globalTime = currentOffset + audioEngine.currentTime

        // Find current aggregated chapter, then advance to the next one.
        let currentIdx = aggregatedChapterIndex(at: globalTime) ?? -1
        let nextIdx = currentIdx + 1
        if state.aggregatedChapters.indices.contains(nextIdx) {
            seekToAggregatedChapter(state.aggregatedChapters[nextIdx])
        } else if let firstEnabled = state.aggregatedChapters.first {
            seekToAggregatedChapter(firstEnabled)
        }
    }

    func previousChapterOrRestart() {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            previousAggregatedChapterOrRestart()
            return
        }
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

    private func previousAggregatedChapterOrRestart() {
        let currentOffset: TimeInterval = {
            guard state.m4bBooks.indices.contains(state.currentIndex) else { return 0 }
            return state.m4bBooks[state.currentIndex].cumulativeStartOffset
        }()
        let globalTime = currentOffset + audioEngine.currentTime

        guard let current = findAggregatedChapter(at: globalTime) else {
            if let first = state.aggregatedChapters.first {
                seekToAggregatedChapter(first)
            }
            return
        }

        // If more than 5s into the chapter, restart it.
        let intraChapterTime = globalTime - current.startSeconds
        if intraChapterTime > 5 {
            seekToAggregatedChapter(current)
            return
        }

        // Otherwise go to the previous chapter.
        let currentIdx = aggregatedChapterIndex(at: globalTime) ?? 0
        let prevIdx = currentIdx - 1
        if state.aggregatedChapters.indices.contains(prevIdx) {
            seekToAggregatedChapter(state.aggregatedChapters[prevIdx])
        } else if let first = state.aggregatedChapters.first {
            seekToAggregatedChapter(first)
        }
    }

    func nextSection() {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            nextAggregatedChapter()
            return
        }
        
        guard let idx = state.currentChapterIndex, let sections = state.chapterSections[idx], !sections.isEmpty else {
            nextChapter()
            return
        }
        
        let t = audioEngine.currentTime
        if let nextSec = sections.first(where: { $0.startSeconds > t + 0.5 }) {
            seekToSection(nextSec)
        } else {
            nextChapter()
        }
    }

    func previousSectionOrRestart() {
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            previousAggregatedChapterOrRestart()
            return
        }
        
        guard let idx = state.currentChapterIndex, let sections = state.chapterSections[idx], !sections.isEmpty else {
            previousChapterOrRestart()
            return
        }
        
        let t = audioEngine.currentTime
        
        if let currentSec = sections.last(where: { $0.startSeconds <= t }), (t - currentSec.startSeconds) > 5 {
            seekToSection(currentSec)
            return
        }
        
        if let prevSec = sections.last(where: { $0.startSeconds < t - 5.0 }) {
            seekToSection(prevSec)
        } else {
            previousChapterOrRestart()
        }
    }

    private func seekToSection(_ section: Chapter) {
        let targetSeconds = section.startSeconds + 0.05
        state.isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
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

    func seekToChapter(at index: Int) {
        guard state.chapters.indices.contains(index), audioEngine.isItemLoaded else { return }
        let c = state.chapters[index]
        let targetSeconds = c.startSeconds + 0.05

        state.isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
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

    // MARK: - Aggregated Chapter Helpers (multi-M4B)

    private func aggregatedChapterIndex(at globalTime: TimeInterval) -> Int? {
        for (i, ch) in state.aggregatedChapters.enumerated() {
            if globalTime >= ch.startSeconds, globalTime < ch.endSeconds {
                return i
            }
        }
        return nil
    }

    private func findAggregatedChapter(at globalTime: TimeInterval) -> AggregatedChapter? {
        guard let idx = aggregatedChapterIndex(at: globalTime) else { return nil }
        return state.aggregatedChapters[idx]
    }

    private func seekToAggregatedChapter(_ agg: AggregatedChapter) {
        let bookOffset: TimeInterval = {
            guard state.m4bBooks.indices.contains(agg.bookIndex) else { return 0 }
            return state.m4bBooks[agg.bookIndex].cumulativeStartOffset
        }()
        let intraBookTime = max(0, agg.startSeconds - bookOffset) + 0.05

        if agg.bookIndex == state.currentIndex {
            // Same book — seek in place.
            state.isManualSeeking = true
            audioEngine.seek(to: intraBookTime) { [weak self] _ in
                guard let self else { return }
                self.state.isManualSeeking = false
                self.coordinator_seekCompleted?(false)
                self.coordinator_refreshProgress?()
                if self.state.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                }
            }
        } else {
            // Different book — load the new track. prepareToPlay will set chapters.
            assert(coordinator_loadTrack != nil,
                   "coordinator_loadTrack must be wired — cross-book navigation required")
            coordinator_loadTrack?(agg.bookIndex, true)
            // Defer seeking until the track is loaded (handled in PlayerModel).
            state.pendingAggregatedChapter = agg
        }
    }

    func resumeAfterSeek() {
        state.isSeekingForChapterBoundary = false
        if state.isPlaying {
            audioEngine.playImmediately(atRate: speed)
            applySpeedToCurrentItem()
        } else {
            coordinator_persistAndSync?(true)
        }
        coordinator_refreshProgress?()
        coordinator_seekCompleted?(false)
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

        let durationAmount = coordinator_seekBackwardDuration?() ?? 30.0
        var target = max(0, current - durationAmount)

        // Clamp to chapter start to prevent unintended chapter crossings
        if state.isMultiM4B, !state.aggregatedChapters.isEmpty {
            let currentOffset = state.m4bBooks.indices.contains(state.currentIndex) ? state.m4bBooks[state.currentIndex].cumulativeStartOffset : 0
            let globalTime = currentOffset + current
            if let idx = aggregatedChapterIndex(at: globalTime) {
                let agg = state.aggregatedChapters[idx]
                let intraBookStart = max(0, agg.startSeconds - currentOffset)
                if target < intraBookStart {
                    target = intraBookStart
                }
            }
        } else if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            let c = state.chapters[idx]
            if target < c.startSeconds {
                target = c.startSeconds
            }
        }

        state.isManualSeeking = true
        audioEngine.seek(to: target) { [weak self] _ in
            self?.state.isManualSeeking = false
            self?.coordinator_seekCompleted?(false)
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

        let durationAmount = coordinator_seekForwardDuration?() ?? 30.0
        let duration = state.durationSeconds ?? 0
        let target = min(duration, current + durationAmount)
        state.isManualSeeking = true
        audioEngine.seek(to: target) { [weak self] _ in
            self?.state.isManualSeeking = false
            self?.coordinator_seekCompleted?(false)
        }
        coordinator_refreshProgress?()
        return false
    }

    func seek(toSeconds targetSeconds: Double) {
        guard audioEngine.isItemLoaded else { return }
        state.isManualSeeking = true
        audioEngine.seek(to: targetSeconds) { [weak self] _ in
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
                        guard let self else { return }
                        if self.isPlaying {
                            self.audioEngine.playImmediately(atRate: self.speed)
                            self.applySpeedToCurrentItem()
                        } else {
                            self.coordinator_persistAndSync?(true)
                        }
                        self.coordinator_refreshProgress?()
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
                guard let self else { return }
                if self.isPlaying {
                    self.audioEngine.playImmediately(atRate: self.speed)
                    self.applySpeedToCurrentItem()
                } else {
                    self.coordinator_persistAndSync?(true)
                }
                self.coordinator_refreshProgress?()
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

        // Pre-buffer the next M4B file when approaching track end (multi-M4B only).
        if state.isMultiM4B, let duration = engine.duration, duration > 0 {
            let remaining = duration - currentTime
            if remaining < 5, remaining > 0,
               let nextIdx = findNextEnabledTrackIndex(in: state.tracks, currentIndex: state.currentIndex),
               state.tracks.indices.contains(nextIdx) {
                engine.prebuffer(next: state.tracks[nextIdx].url)
            }
        }
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

    func audioEngineOutputDeviceDisconnected(_ engine: AudioEngine) {
        // Output device (headphones / aux / Bluetooth) was unplugged. Pause rather
        // than let playback fall through to the speaker. pause() drives the full state
        // update — Now Playing, watch sync, pause timestamp — and, unlike an
        // interruption, never arms wasPlayingBeforeInterruption, so playback stays
        // paused until the user explicitly resumes.
        pause()
    }
}
