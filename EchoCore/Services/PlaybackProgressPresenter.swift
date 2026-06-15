import Foundation
import UIKit

// MARK: - PlaybackProgressPresenter

/// Computes and presents playback progress, updates the system Now Playing
/// info center, and manages elapsed-time display. Mutates PlaybackState
/// progress fields directly and delegates Now Playing metadata to
/// NowPlayingController.
@MainActor
final class PlaybackProgressPresenter {

    // MARK: - Dependencies (set by PlayerModel)

    @ObservationIgnored var state: PlaybackState?
    @ObservationIgnored var audioEngine: AudioEngine?
    @ObservationIgnored var nowPlayingController: NowPlayingController?

    /// Value providers for properties owned by PlayerModel.
    @ObservationIgnored var speedProvider: (() -> Float)?
    @ObservationIgnored var currentTitleProvider: (() -> String)?
    @ObservationIgnored var currentSubtitleProvider: (() -> String)?
    @ObservationIgnored var currentDisplayArtworkProvider: (() -> UIImage?)?
    @ObservationIgnored var thumbnailImageProvider: (() -> UIImage?)?

    /// Callbacks for cross-service coordination.
    @ObservationIgnored var onSyncToWatch: (() -> Void)?
    @ObservationIgnored var onChapterOutOfBounds: (() -> Void)?

    // MARK: - Elapsed time

    func updateElapsedTime() {
        guard let audioEngine, let nowPlayingController, let state else { return }
        guard audioEngine.isItemLoaded else { return }
        let current = audioEngine.currentTime
        guard current.isFinite else { return }

        let chapterOffset: TimeInterval?
        if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            chapterOffset = state.chapters[idx].startSeconds
        } else {
            chapterOffset = nil
        }

        nowPlayingController.updateElapsedTime(current, chapterStartOffset: chapterOffset)
    }

    // MARK: - Now Playing info

    func updateNowPlayingInfo(isPaused: Bool) {
        guard let audioEngine, let nowPlayingController, let state else { return }
        let elapsed = audioEngine.currentTime

        var params = NowPlayingController.NowPlayingParams()
        params.title = currentTitleProvider?() ?? ""
        params.subtitle = currentSubtitleProvider?() ?? ""
        params.elapsed = elapsed
        params.isPaused = isPaused
        params.playbackRate = speedProvider?() ?? 1.0
        params.artworkImage = currentDisplayArtworkProvider?() ?? thumbnailImageProvider?()
        params.duration = state.durationSeconds ?? 0

        if state.chapters.count >= 2, let idx = state.currentChapterIndex {
            let c = state.chapters[idx]
            params.chapterIndex = idx
            params.chapterElapsed = max(0, elapsed - c.startSeconds)
            params.chapterDuration = c.endSeconds - c.startSeconds
        } else {
            let subtitle = currentSubtitleProvider?() ?? ""
            params.albumTitle = subtitle.isEmpty ? nil : subtitle
        }

        nowPlayingController.updateNowPlayingInfo(params)
    }

    // MARK: - Progress

    func updateProgress() {
        guard let audioEngine, let state else { return }
        guard audioEngine.isItemLoaded else {
            state.progressFraction = 0
            state.progressText = "--:--"
            state.elapsedText = "--:--"
            state.durationText = "--:--"
            return
        }

        let elapsed = audioEngine.currentTime
        let speed = max(0.1, Double(speedProvider?() ?? 1.0))  // Clamp to avoid Inf/NaN in remaining labels

        // §7.3: coarse book-level percent for dashboard cards — set only when the
        // integer changes, so observers re-render ~1 Hz instead of every tick.
        if let duration = state.durationSeconds, duration > 0 {
            let percent = Int(min(1.0, max(0, elapsed / duration)) * 100)
            if state.bookProgressPercent != percent { state.bookProgressPercent = percent }
        }

        // Multi-M4B: book-level progress (overrides chapter-level fraction below).
        if state.isMultiM4B, state.totalBookDuration > 0 {
            let bookOffset: TimeInterval = {
                guard state.m4bBooks.indices.contains(state.currentIndex) else { return 0 }
                return state.m4bBooks[state.currentIndex].cumulativeStartOffset
            }()
            let bookElapsed = bookOffset + elapsed
            let frac = min(1, max(0, bookElapsed / state.totalBookDuration))
            let didChange = abs(state.progressFraction - frac) > 0.005
            state.progressFraction = frac
            state.elapsedText = NowPlayingController.formatTime(max(0, bookElapsed) / speed)
            let remaining = max(0, state.totalBookDuration - bookElapsed) / speed
            state.progressText = "-\(NowPlayingController.formatTime(remaining))"
            state.durationText = NowPlayingController.formatTime(state.totalBookDuration / speed)
            if didChange { onSyncToWatch?() }
        }

        if state.chapters.count >= 2 {
            if let idx = state.currentChapterIndex {
                let c = state.chapters[idx]
                if elapsed.isFinite, elapsed < c.startSeconds - 0.1 || elapsed >= c.endSeconds + 0.1
                {
                    onChapterOutOfBounds?()
                }
            } else {
                onChapterOutOfBounds?()
            }

            if let idx = state.currentChapterIndex {
                let c = state.chapters[idx]
                let chapterDuration = c.endSeconds - c.startSeconds
                let chapterElapsed = elapsed - c.startSeconds

                // Multi-M4B: book-level progress is already set above; skip chapter-level override.
                if state.isMultiM4B { return }

                if chapterElapsed.isFinite, chapterDuration.isFinite, chapterDuration > 0 {
                    let frac = min(1, max(0, chapterElapsed / chapterDuration))
                    let didChange = abs(state.progressFraction - frac) > 0.005
                    state.progressFraction = frac
                    let remaining = max(0, chapterDuration - chapterElapsed) / speed
                    state.progressText = "-\(NowPlayingController.formatTime(remaining))"
                    state.elapsedText = NowPlayingController.formatTime(
                        max(0, chapterElapsed) / speed)
                    state.durationText = NowPlayingController.formatTime(chapterDuration / speed)
                    if didChange { onSyncToWatch?() }
                    return
                }
            }
        }

        let duration = state.durationSeconds ?? 0

        guard elapsed.isFinite, duration.isFinite, duration > 0 else {
            state.progressFraction = 0
            state.progressText = "--:--"
            state.elapsedText = "--:--"
            state.durationText = "--:--"
            return
        }

        let frac = min(1, max(0, elapsed / duration))
        let didChange = abs(state.progressFraction - frac) > 0.005
        state.progressFraction = frac

        let remaining = max(0, duration - elapsed) / speed
        state.progressText = "-\(NowPlayingController.formatTime(remaining))"
        state.elapsedText = NowPlayingController.formatTime(max(0, elapsed) / speed)
        state.durationText = NowPlayingController.formatTime(duration / speed)
        if didChange { onSyncToWatch?() }
    }
}
