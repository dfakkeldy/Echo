import AVFoundation
import Foundation
import GRDB

// MARK: - On-device narration playback

extension PlayerModel {

    /// Plays an audio-less study book's narration through the main playback
    /// pipeline: each chapter is rendered to a file and injected as a `Track`,
    /// so CarPlay, the lock screen, and the scrubber drive it like a normal
    /// audiobook. Chapter 1 starts playing as soon as it's rendered; the rest
    /// render ahead and append, and the pipeline advances automatically.
    ///
    /// Safe to call right after `loadFolder` for a book that has no audio: it
    /// renders nothing and returns if the book has no narratable EPUB text.
    func startNarrationPlayback(voice: NarrationVoice = VoiceCatalog.default) {
        guard let audiobookID = folderURL?.absoluteString,
            let db = databaseService?.writer
        else { return }

        narrationRenderTask?.cancel()
        narrationPlaybackState.reset()
        state.narrationRenderInFlight = true
        state.awaitingNarrationChapter = false

        // Show the book + a preparing status on Now Playing / lock screen while
        // the first chapter renders, instead of the audio-less placeholder.
        if let title = folderURL?.deletingPathExtension().lastPathComponent {
            state.currentTitle = title
        }
        state.currentSubtitle = String(localized: "Preparing narration…")
        progressPresenter.updateNowPlayingInfo(isPaused: true)

        let cacheDirectory = Self.narrationCacheDirectory()
        let service = NarrationService(
            db: db, audiobookID: audiobookID, tts: narrationTTS,
            audioWriter: AVFoundationAudioWriter(), cacheDirectory: cacheDirectory,
            state: narrationPlaybackState)

        narrationRenderTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Wait for loadFolder's no-audio EPUB import to finish so a
                // first-ever open isn't read before its blocks are committed.
                await self.playerLoadingCoordinator.documentImportTask?.value
                // visibleBlocks (not blocks) so blocks the user marked "Not in
                // Audio" in the reader are excluded from narration, matching the
                // alignment/timeline paths.
                let blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
                let plan = NarrationChapterPlanner.plan(from: blocks)
                guard !plan.isEmpty else {
                    self.state.narrationRenderInFlight = false
                    return
                }
                // Resume at the last-played chapter (forward-only). The pipeline's
                // own position-restore seeks within that chapter, because the
                // narration Track.id is the deterministic per-chapter file URL.
                let chapters: [NarrationChapterPlanner.PlannedChapter]
                if let lastTrackID = self.persistence.getLastTrack(for: audiobookID),
                    let fileName = URL(string: lastTrackID)?.lastPathComponent,
                    let resumeIndex = NarrationFileNaming.chapterIndex(fromFileName: fileName)
                {
                    chapters = NarrationChapterPlanner.resume(
                        plan, startingAtChapterIndex: resumeIndex)
                } else {
                    chapters = plan
                }

                // Pay the one-time ANE model compile before the first chapter.
                try await self.narrationTTS.prepare()

                let lookAhead = 2
                for (offset, chapter) in chapters.enumerated() {
                    try Task.checkCancellation()
                    // Render-ahead backpressure: don't synthesize more than
                    // `lookAhead` chapters past the one currently playing, and
                    // don't render while paused. (offset 0 always renders first.)
                    while offset > 0,
                        self.folderURL?.absoluteString == audiobookID,
                        self.state.currentIndex + lookAhead < offset || !self.isPlaying
                    {
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                    }
                    guard self.folderURL?.absoluteString == audiobookID else { return }
                    try await service.renderChapter(
                        chapterIndex: chapter.index, blocks: chapter.blocks, voice: voice.id)
                    try Task.checkCancellation()
                    // Bail if the user switched books while this chapter rendered.
                    guard self.folderURL?.absoluteString == audiobookID else { return }

                    let fileURL = cacheDirectory.appendingPathComponent(
                        NarrationFileNaming.chapterFileName(
                            audiobookID: audiobookID, chapterIndex: chapter.index, voice: voice.id))
                    let track = Track(
                        url: fileURL, title: String(localized: "Chapter \(chapter.index + 1)"))

                    if offset == 0 {
                        // First chapter: start playing through the pipeline.
                        self.tracks = [track]
                        self.playerLoadingCoordinator.prepareToPlay(index: 0, autoplay: true)
                    } else {
                        // Render-ahead: append so the player advances into it.
                        self.tracks.append(track)
                        // If playback paused at the end of the queue waiting for
                        // this chapter, advance into it now.
                        if self.state.awaitingNarrationChapter {
                            self.state.awaitingNarrationChapter = false
                            self.playbackController.nextTrack()
                        }
                    }
                }
                // All chapters rendered and queued.
                guard self.folderURL?.absoluteString == audiobookID else { return }
                self.state.narrationRenderInFlight = false
                self.narrationPlaybackState.complete()
            } catch is CancellationError {
                // Switched books or stopped — loadFolder resets the flags.
            } catch {
                // Don't stamp a stale failure onto a book the user switched to.
                guard self.folderURL?.absoluteString == audiobookID else { return }
                self.state.narrationRenderInFlight = false
                self.narrationPlaybackState.fail(error.localizedDescription)
            }
        }
    }

    /// App-owned, stable location for rendered narration audio — survives the
    /// session (unlike the temporary directory, which can be purged mid-play).
    private static func narrationCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
