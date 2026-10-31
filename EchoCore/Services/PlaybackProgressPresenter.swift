// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit

// MARK: - ProgressPublicationPolicy

/// Decides when a playback-progress tick should publish to the Watch and the
/// App Group position. Compares against the last *published* fraction, not the
/// previous tick's: on a long chapter a 0.5 s tick moves the fraction far less
/// than the threshold, so a per-tick comparison never fires from playback alone.
/// While playing, a publication is also forced once `maximumInterval` has
/// passed, which bounds how stale the published position can get.
struct ProgressPublicationPolicy {
    var fractionThreshold: Double
    var maximumInterval: TimeInterval
    private var lastPublishedFraction: Double?
    private var lastPublishedAt: Date?

    /// The interval sits a tick below 5 s so the 0.5 s timer, with jitter,
    /// still publishes within 5 wall-clock seconds.
    init(fractionThreshold: Double = 0.005, maximumInterval: TimeInterval = 4.5) {
        self.fractionThreshold = fractionThreshold
        self.maximumInterval = maximumInterval
    }

    mutating func shouldPublish(fraction: Double, isPlaying: Bool, now: Date = .now) -> Bool {
        let moved = lastPublishedFraction.map { abs($0 - fraction) > fractionThreshold } ?? true
        let due =
            isPlaying && (lastPublishedAt.map { now.timeIntervalSince($0) >= maximumInterval } ?? true)
        guard moved || due else { return false }
        lastPublishedFraction = fraction
        lastPublishedAt = now
        return true
    }

    /// Forget the baseline so the next tick (e.g. for a newly loaded item)
    /// publishes at once.
    mutating func reset() {
        lastPublishedFraction = nil
        lastPublishedAt = nil
    }
}

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

    @ObservationIgnored private var publicationPolicy = ProgressPublicationPolicy()
    @ObservationIgnored var now: () -> Date = { .now }

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
            publicationPolicy.reset()
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
        let bookElapsed = state.bookTime(forCurrentTrackOffset: elapsed)
        let bookDuration = state.effectiveBookDuration
        if bookDuration > 0 {
            let percent = Int(min(1.0, max(0, bookElapsed / bookDuration)) * 100)
            if state.bookProgressPercent != percent { state.bookProgressPercent = percent }
        }

        if state.chapters.count >= 2 {
            // Accepted EOF must recalculate the chapter even when the final
            // chapter is shorter than the ordinary boundary tolerance below.
            if let duration = audioEngine.duration, duration.isFinite, duration > 0,
                elapsed.isFinite, elapsed >= duration
            {
                onChapterOutOfBounds?()
            }
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

                if chapterElapsed.isFinite, chapterDuration.isFinite, chapterDuration > 0 {
                    let frac = state.currentScopeProgressFraction(forCurrentTrackOffset: elapsed)
                    let shouldPublish = publicationPolicy.shouldPublish(
                        fraction: frac, isPlaying: audioEngine.isPlaying, now: now())
                    state.progressFraction = frac
                    let remaining = max(0, chapterDuration - chapterElapsed) / speed
                    state.progressText = "-\(NowPlayingController.formatTime(remaining))"
                    state.elapsedText = NowPlayingController.formatTime(
                        max(0, chapterElapsed) / speed)
                    state.durationText = NowPlayingController.formatTime(chapterDuration / speed)
                    if shouldPublish { onSyncToWatch?() }
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

        let frac = state.currentScopeProgressFraction(forCurrentTrackOffset: elapsed)
        let shouldPublish = publicationPolicy.shouldPublish(
            fraction: frac, isPlaying: audioEngine.isPlaying, now: now())
        state.progressFraction = frac

        let remaining = max(0, duration - elapsed) / speed
        state.progressText = "-\(NowPlayingController.formatTime(remaining))"
        state.elapsedText = NowPlayingController.formatTime(max(0, elapsed) / speed)
        state.durationText = NowPlayingController.formatTime(duration / speed)
        if shouldPublish { onSyncToWatch?() }
    }
}
