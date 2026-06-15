import AVFoundation
import Foundation
import GRDB
import OSLog

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

        // Stop playback before evicting stale-voice files so the AVPlayer isn't
        // holding a reference to a file we're about to delete (§5.1).
        playbackController.stop()

        // Show the book + a preparing status on Now Playing / lock screen while
        // the first chapter renders, instead of the audio-less placeholder.
        if let title = folderURL?.deletingPathExtension().lastPathComponent {
            state.currentTitle = title
        }
        state.currentSubtitle = String(localized: "Preparing narration…")
        progressPresenter.updateNowPlayingInfo(isPaused: true)

        let cacheDirectory = Self.narrationCacheDirectory()
        // Drop this book's files rendered with a previous voice so the store
        // doesn't grow unbounded across voice changes.
        let bookPrefix = NarrationFileNaming.chapterPrefix(audiobookID: audiobookID)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
            for stale in NarrationCacheStore.staleVoiceFiles(
                names, bookPrefix: bookPrefix, currentVoice: voice.id)
            {
                try? FileManager.default.removeItem(
                    at: cacheDirectory.appendingPathComponent(stale))
            }
        }
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

                // Copy the EPUB's first image (typically the cover) into the
                // narration cache so Now Playing and the lock screen can show
                // artwork instead of a placeholder icon. Query ALL image blocks
                // (not just visibleBlocks) because the cover is front-matter
                // and marked is_hidden during import.
                let coverLogger = Logger(category: "NarrationCover")
                let allBlocks = (try? EPubBlockDAO(db: db).allBlocks(for: audiobookID)) ?? []
                // Prefer front-matter images (the cover is always front-matter),
                // fall back to any image if the EPUB doesn't separate front/body.
                let imageBlocks = allBlocks.filter {
                    $0.blockKind == EPubBlockRecord.Kind.image.rawValue
                }
                let frontMatterImages = imageBlocks.filter(\.isFrontMatter)
                let candidates = frontMatterImages.isEmpty ? imageBlocks : frontMatterImages
                coverLogger.debug(
                    "Searching for cover: \(allBlocks.count) total, \(imageBlocks.count) image, \(frontMatterImages.count) front-matter"
                )
                if let coverBlock =
                    candidates
                    .sorted(by: { $0.sequenceIndex < $1.sequenceIndex })
                    .first,
                    let imagePath = coverBlock.imagePath,
                    FileManager.default.fileExists(atPath: imagePath)
                {
                    let coverSource = URL(fileURLWithPath: imagePath)
                    let ext =
                        coverSource.pathExtension.isEmpty ? "jpg" : coverSource.pathExtension
                    let coverDest = cacheDirectory.appendingPathComponent("cover")
                        .appendingPathExtension(ext)
                    // Remove any stale cover from a previous voice/render run.
                    try? FileManager.default.removeItem(at: coverDest)
                    do {
                        try FileManager.default.copyItem(at: coverSource, to: coverDest)
                        coverLogger.info("Copied EPUB cover to \(coverDest.path)")
                    } catch {
                        coverLogger.warning(
                            "Failed to copy EPUB cover: \(error.localizedDescription)")
                    }
                } else {
                    coverLogger.debug("No cover image found in EPUB blocks")
                }

                let plan = NarrationChapterPlanner.plan(from: blocks)
                guard !plan.isEmpty else {
                    // No narratable text: replace the interim "Preparing narration…"
                    // status (set synchronously above) with a clear reason instead
                    // of a silent blank, so the user understands why playback never
                    // started rather than being left staring at an empty subtitle (§5.5).
                    self.state.narrationRenderInFlight = false
                    self.state.currentSubtitle = String(localized: "No text to narrate")
                    self.progressPresenter.updateNowPlayingInfo(isPaused: true)
                    return
                }
                // Resume at the last-played chapter, but keep the FULL book in the
                // queue (§5.3 / Phase 4B). `chapters` (the forward set, resume→end)
                // renders + plays first; `earlierChapters` (resume-1…0, descending)
                // renders afterwards and is prepended so the whole chapter list is
                // present without a cold re-render of the entire book before playback
                // starts. The pipeline's own position-restore seeks within the resume
                // chapter, because the narration Track.id is the per-chapter file URL.
                let chapters: [NarrationChapterPlanner.PlannedChapter]
                let earlierChapters: [NarrationChapterPlanner.PlannedChapter]
                if let lastTrackID = self.persistence.getLastTrack(for: audiobookID),
                    let fileName = URL(string: lastTrackID)?.lastPathComponent,
                    let resumeIndex = NarrationFileNaming.chapterIndex(fromFileName: fileName)
                {
                    chapters = NarrationChapterPlanner.resume(
                        plan, startingAtChapterIndex: resumeIndex)
                    earlierChapters = NarrationChapterPlanner.beforeResume(
                        plan, startingAtChapterIndex: resumeIndex)
                } else {
                    chapters = plan
                    earlierChapters = []
                }

                // Pay the one-time ANE model compile before the first chapter.
                try await self.narrationTTS.prepare()

                let lookAhead = 2
                for (offset, chapter) in chapters.enumerated() {
                    try Task.checkCancellation()
                    // Render-ahead backpressure via NarrationRenderPolicy
                    // (extracted for testability — see NarrationRenderPolicyTests).
                    while NarrationRenderPolicy.shouldPauseRender(
                        offset: offset,
                        currentPlaybackIndex: self.state.currentIndex,
                        lookAhead: lookAhead,
                        isPlaying: self.isPlaying,
                        isAwaitingChapter: self.state.awaitingNarrationChapter
                    ),
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    {
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                    }
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }
                    try await service.renderChapter(
                        chapterIndex: chapter.index, blocks: chapter.blocks, voice: voice.id)
                    try Task.checkCancellation()
                    // Bail if the user switched books while this chapter rendered.
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }

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

                // Backfill the earlier chapters so resume keeps the FULL queue
                // (§5.3 / Phase 4B). Each renders then prepends at the front;
                // `currentIndex` advances by one per insert so it keeps pointing at
                // the audio actually playing — the queue and the single player node
                // are decoupled, so a prepend never reloads or interrupts the
                // current file (see PlaybackController). Only rendered tracks ever
                // enter the queue, so the player can never hit a missing-file stall.
                // These chapters are behind playback, so look-ahead backpressure
                // doesn't apply; the book-switch + cancellation guards still do.
                for chapter in earlierChapters {
                    try Task.checkCancellation()
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }
                    try await service.renderChapter(
                        chapterIndex: chapter.index, blocks: chapter.blocks, voice: voice.id)
                    try Task.checkCancellation()
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }

                    let fileURL = cacheDirectory.appendingPathComponent(
                        NarrationFileNaming.chapterFileName(
                            audiobookID: audiobookID, chapterIndex: chapter.index, voice: voice.id))
                    let track = Track(
                        url: fileURL, title: String(localized: "Chapter \(chapter.index + 1)"))
                    self.tracks.insert(track, at: 0)
                    // The playing track shifted one slot right; keep currentIndex on it.
                    self.state.currentIndex += 1
                }

                // All chapters rendered and queued.
                guard
                    NarrationRenderPolicy.bookWasSwitched(
                        currentFolderURL: self.folderURL?.absoluteString, audiobookID: audiobookID
                    ) == false
                else { return }
                self.state.narrationRenderInFlight = false
                self.narrationPlaybackState.complete()
            } catch is CancellationError {
                // Switched books or stopped — loadFolder resets the flags.
            } catch {
                // Don't stamp a stale failure onto a book the user switched to.
                guard
                    NarrationRenderPolicy.bookWasSwitched(
                        currentFolderURL: self.folderURL?.absoluteString, audiobookID: audiobookID
                    ) == false
                else { return }
                self.state.narrationRenderInFlight = false
                self.narrationPlaybackState.fail(error.localizedDescription)
            }
        }
    }

    /// App-owned, durable location for rendered narration audio. Application
    /// Support (not Caches) so iOS won't purge a queued chapter mid-play, and it's
    /// excluded from iCloud/iTunes backup since it's regenerable.
    static func narrationCacheDirectory() -> URL {
        let fm = FileManager.default
        var base =
            (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory)
            .appendingPathComponent("Narration", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }
}
