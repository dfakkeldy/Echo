import Foundation
import AVFoundation
import os.log

// MARK: - ChapterLoadingCoordinator

/// Loads chapter metadata, resolves the current chapter from player time,
/// and loads the track duration for Now Playing display. Extracted from
/// PlayerModel to separate chapter/asset loading from playback orchestration.
final class ChapterLoadingCoordinator {

    // MARK: - Dependencies (set by PlayerModel)

    @ObservationIgnored var state: PlaybackState?
    @ObservationIgnored var audioEngine: AudioEngine?
    @ObservationIgnored var persistence: Persistence?
    @ObservationIgnored var timelinePersistence: PlayerTimelinePersistenceService?

    /// Value providers for properties owned by PlayerModel.
    @ObservationIgnored var isPlayingProvider: (() -> Bool)?
    @ObservationIgnored var databaseServiceProvider: (() -> DatabaseService?)?

    /// Callbacks for cross-service coordination.
    @ObservationIgnored var onUpdateNowPlayingInfo: ((Bool) -> Void)?
    @ObservationIgnored var onSyncToWatch: (() -> Void)?
    @ObservationIgnored var onUpdateProgress: (() -> Void)?
    @ObservationIgnored var onComputeWordClouds: (() -> Void)?
    /// Called after duration is loaded and state is updated. The callback
    /// receives the duration in seconds and should handle deep-link seeks
    /// or saved-progress restoration.
    @ObservationIgnored var onDurationLoaded: ((TimeInterval) -> Void)?

    // MARK: - Chapter loading

    func loadChaptersForCurrentItem() async {
        guard let audioEngine, let state, let persistence else { return }
        guard audioEngine.isItemLoaded,
              state.tracks.indices.contains(state.currentIndex) else { return }

        // Capture all necessary track information safely BEFORE any yield point (await)
        let track = state.tracks[state.currentIndex]
        let trackURL = track.url
        let trackKey = trackURL.absoluteString
        let trackTitle = track.title
        let trackCount = state.tracks.count

        // Multi-M4B: chapters already loaded from M4BParser with intra-book offsets.
        if state.isMultiM4B, !state.chapters.isEmpty { return }

        let asset = AVURLAsset(url: trackURL)

        var built: [Chapter] = []
        let ext = trackURL.pathExtension.lowercased()
        if ext == "m4b" || ext == "m4a" {
            built = await ChapterService.parseChapters(from: asset)
        }

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

        // For files with no parsed chapters, create a single chapter spanning the book
        // so the timeline feed always has at least one chapter marker.
        if built.isEmpty {
            let duration = state.durationSeconds ?? 0
            built = [Chapter(
                index: 0,
                title: trackTitle,
                startSeconds: 0,
                endSeconds: duration,
                isEnabled: true
            )]
        }

        // Files with a single chapter that spans the whole book are still valid
        // timeline entries. Only skip chapter-based Now Playing UI when < 2.
        if built.count >= 2 {
            state.chapters = built
            updateCurrentChapterFromPlayerTime()
        } else {
            state.chapters = built
            state.currentChapterIndex = nil
            state.currentSubtitle = ""
            onUpdateNowPlayingInfo?(!(isPlayingProvider?() ?? false))
            onSyncToWatch?()
        }

        // Persist chapters and ingest timeline items for every book,
        // regardless of chapter count or file type.
        if let db = databaseServiceProvider?(),
           let audiobookID = state.folderURL?.absoluteString {
            let records = built.enumerated().map { (i, ch) in
                ChapterRecord(
                    id: nil,
                    audiobookID: audiobookID,
                    title: ch.title ?? "Chapter \(i + 1)",
                    startSeconds: ch.startSeconds,
                    endSeconds: ch.endSeconds,
                    isEnabled: ch.isEnabled,
                    sortOrder: i,
                    playlistPosition: nil
                )
            }
            do {
                try ChapterDAO(db: db.writer).deleteAll(for: audiobookID)
                try ChapterDAO(db: db.writer).insertAll(records, audiobookID: audiobookID)
            } catch {
                Logger(subsystem: "com.orbitaudiobooks", category: "PlayerModel")
                    .error("Failed to persist chapters: \(error.localizedDescription)")
            }

            // Multi-file folders get a full ingestion pass in loadFolder;
            // avoid wiping all items on every track switch for those cases.
            if trackCount <= 1 {
                let transcription = state.transcription
                let enhanced = state.enhancedTranscription
                let fURL = state.folderURL
                let timelinePersistence = self.timelinePersistence
                Task {
                    await timelinePersistence?.ingestTimelineItems(
                        audiobookID: audiobookID,
                        audioURL: trackURL,
                        chapters: built,
                        transcription: transcription,
                        enhancedTranscription: enhanced,
                        folderURL: fURL
                    )
                }
            }
        }
        onComputeWordClouds?()
    }

    // MARK: - Duration loading

    func loadDurationForNowPlaying() async {
        guard let audioEngine, let state else { return }
        guard let seconds = audioEngine.duration, seconds > 0 else { return }
        state.durationSeconds = seconds
        onUpdateNowPlayingInfo?(!(isPlayingProvider?() ?? false))
        onUpdateProgress?()
        // Deep-link seek and saved-progress restoration are handled by
        // PlayerModel via onDurationLoaded so the service stays focused.
        onDurationLoaded?(seconds)
    }

    // MARK: - Chapter tracking

    func updateCurrentChapterFromPlayerTime() {
        guard let state, let audioEngine else { return }
        guard state.chapters.count >= 2, audioEngine.isItemLoaded else { return }
        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        // Find all chapters that contain the current time
        let matching = state.chapters.filter { t >= $0.startSeconds && t < $0.endSeconds }

        // Pick the most specific one (shortest duration) to ignore global/overlapping chapters
        if let bestMatch = matching.min(by: { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) }),
           let idx = state.chapters.firstIndex(of: bestMatch) {

            if state.currentChapterIndex != idx {
                state.currentChapterIndex = idx
                let c = state.chapters[idx]
                if let title = c.title, !title.isEmpty {
                    state.currentSubtitle = title
                } else {
                    state.currentSubtitle = String(localized: "Chapter \(idx + 1)")
                }
                onUpdateNowPlayingInfo?(!(isPlayingProvider?() ?? false))
                onSyncToWatch?()
            }
        }
    }
}
