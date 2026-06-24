#if os(iOS)
    // SPDX-License-Identifier: GPL-3.0-or-later
    import AVFoundation
    import Foundation
    import GRDB
    import OSLog

    /// Pure rule for "this book is narrated on-device" (vs an imported audiobook):
    /// it has EPUB text, and any tracks present are files in the narration cache.
    /// Stable before render (no tracks) and during render (narration-cache tracks).
    enum NarrationBookClassifier {
        static func isNarrationBook(
            hasEPUB: Bool, trackPaths: [String], narrationCachePath: String
        ) -> Bool {
            guard hasEPUB else { return false }
            return trackPaths.allSatisfy { $0.hasPrefix(narrationCachePath) }
        }
    }

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
            // History: the A14 (and older) ANE trapped on the Kokoro vocoder for real-
            // book input (§3.1, device-confirmed) — an uncatchable BNNS SIGTRAP on
            // certain shapes. The current engine runs on ONNX Runtime's CPU EP and never
            // touches the ANE, so on-device narration is universally available; this
            // capability check stays as the one gate every entry point (Listen, the Play
            // button, CarPlay) shares.
            guard NarrationCapability.supportsOnDeviceNarration else { return }
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
            if let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            {
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
                state: narrationPlaybackState,
                pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })

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
                    // Surface the full chapter outline (incl. any excluded chapters)
                    // now that the EPUB blocks are committed, so the playlist shows
                    // every chapter, not just the ones about to render.
                    self.refreshNarrationOutline()
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

                    // Pay the one-time model download + ONNX session load before the
                    // first chapter, reporting real progress so the user sees
                    // "Downloading… %" / "Loading voice models… N of M" instead of a
                    // silent "Preparing narration…" spinner.
                    try await self.narrationTTS.prepare(progress: { [weak self] p in
                        Task { @MainActor in
                            guard let self else { return }
                            switch p {
                            case .downloadingModels(let f):
                                self.narrationPlaybackState.update(
                                    phase: .preparingEngine, progress: 0.5 * f,
                                    statusMessage:
                                        "Downloading voice models… \(Int(min(max(f, 0), 1) * 100))%"
                                )
                            case .compilingModels(let done, let total):
                                let frac = total > 0 ? Double(done) / Double(total) : 0
                                self.narrationPlaybackState.update(
                                    phase: .preparingEngine, progress: 0.5 + 0.5 * frac,
                                    statusMessage: "Loading voice models… \(done) of \(total)")
                            case .ready:
                                self.narrationPlaybackState.update(
                                    phase: .preparingEngine, progress: 1.0,
                                    statusMessage: "Voice models ready")
                            }
                        }
                    })

                    let lookAhead = 2
                    for (offset, chapter) in chapters.enumerated() {
                        try Task.checkCancellation()

                        let fileURL = cacheDirectory.appendingPathComponent(
                            NarrationFileNaming.chapterFileName(
                                audiobookID: audiobookID, chapterIndex: chapter.index,
                                voice: voice.id))

                        // Persistence: a chapter already rendered for this voice is
                        // reused as-is. Re-synthesising it would burn seconds of CPU
                        // time + battery + heat per chapter and defeat the durable
                        // cache (and make export / per-item narration pointlessly
                        // expensive). So we only render — and only apply look-ahead
                        // backpressure — when the file is actually missing.
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
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
                            // Lock screen: name the chapter being prepared (the in-app NarrationStatusView
                            // already shows the per-block bar; the lock screen otherwise sits on the stale
                            // "Preparing narration…"). The per-block percent is refreshed in the cover
                            // callback below.
                            self.state.currentSubtitle = NarrationProgressText.subtitle(
                                chapterDisplayNumber: chapter.displayNumber, fraction: 0)
                            self.progressPresenter.updateNowPlayingInfo(isPaused: true)
                            try await service.renderChapter(
                                chapterIndex: chapter.index, chapterNumber: chapter.displayNumber,
                                blocks: chapter.blocks, voice: voice.id,
                                onBlockProgress: { [weak self] displayNumber, fraction in
                                    guard let self else { return }
                                    self.state.currentSubtitle = NarrationProgressText.subtitle(
                                        chapterDisplayNumber: displayNumber, fraction: fraction)
                                    // `isPaused: true` is a prepare-time precondition: this
                                    // callback only fires while the chapter is still rendering
                                    // (render-then-play), so no audio is playing yet. If this
                                    // callback is ever reused on a live-playback path, derive
                                    // the flag from `self.isPlaying` instead of hardcoding it.
                                    self.progressPresenter.updateNowPlayingInfo(isPaused: true)
                                })
                            try Task.checkCancellation()
                            // Bail if the user switched books while this chapter rendered.
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.folderURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                        }

                        let track = Track(
                            url: fileURL,
                            title: String(localized: "Chapter \(chapter.displayNumber)"))

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
                        let fileURL = cacheDirectory.appendingPathComponent(
                            NarrationFileNaming.chapterFileName(
                                audiobookID: audiobookID, chapterIndex: chapter.index,
                                voice: voice.id))
                        // Reuse an already-rendered chapter (persistence) — only
                        // synthesise the ones missing from the cache.
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.folderURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                            try await service.renderChapter(
                                chapterIndex: chapter.index, chapterNumber: chapter.displayNumber,
                                blocks: chapter.blocks, voice: voice.id)
                            try Task.checkCancellation()
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.folderURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                        }

                        let track = Track(
                            url: fileURL,
                            title: String(localized: "Chapter \(chapter.displayNumber)"))
                        self.tracks.insert(track, at: 0)
                        // The playing track shifted one slot right; keep currentIndex on it.
                        self.state.currentIndex += 1
                    }

                    // All chapters rendered and queued.
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
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
                            currentFolderURL: self.folderURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }
                    self.state.narrationRenderInFlight = false
                    self.narrationPlaybackState.fail(error.localizedDescription)
                }
            }
        }

        // MARK: - Chapter outline (full EPUB outline + tap-to-exclude)

        /// True when the playlist should show the narration chapter outline: an EPUB
        /// book whose tracks (if any) are narration-cache files, not imported audio.
        var isNarrationBook: Bool {
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: hasEPUB,
                trackPaths: state.tracks.map { $0.url.path },
                narrationCachePath: Self.narrationCacheDirectory().path)
        }

        /// The full EPUB chapter outline for the current narration book.
        var narrationOutline: [NarrationOutlineChapter] { state.narrationOutline }

        /// Voice used to key narration cache filenames (matches the render path's
        /// resolution, so `isRendered` lines up with the files actually written).
        private var narrationVoiceForFiles: VoiceID {
            VoiceCatalog.voice(for: VoiceID(settingsManager?.narrationVoiceID ?? ""))?.id
                ?? VoiceCatalog.default.id
        }

        /// Rebuilds `state.narrationOutline` from the book's EPUB blocks + which
        /// chapter files exist. User-driven (sheet open / narration start / toggle) —
        /// never per rendered chapter, so it doesn't reintroduce O(chapters²) work.
        func refreshNarrationOutline() {
            guard let audiobookID = folderURL?.absoluteString,
                let db = databaseService?.writer
            else {
                state.narrationOutline = []
                return
            }
            let blocks = (try? EPubBlockDAO(db: db).allBlocks(for: audiobookID)) ?? []
            let cacheDir = Self.narrationCacheDirectory()
            let voice = narrationVoiceForFiles
            state.narrationOutline = NarrationOutlineBuilder.build(allBlocks: blocks) { idx in
                let url = cacheDir.appendingPathComponent(
                    NarrationFileNaming.chapterFileName(
                        audiobookID: audiobookID, chapterIndex: idx, voice: voice))
                return FileManager.default.fileExists(atPath: url.path)
            }
        }

        /// Toggles whether a chapter is narrated. Excluding hides all its blocks
        /// (dropped from `plan(from: visibleBlocks)` → never synthesized or queued);
        /// including unhides them. A rendered file is left on disk so re-including is
        /// instant. A newly-excluded chapter is pulled from the live queue unless it
        /// is the one currently playing (that finishes; future renders exclude it).
        func toggleNarrationChapterExcluded(chapterIndex: Int) {
            guard let audiobookID = folderURL?.absoluteString,
                let db = databaseService?.writer
            else { return }
            let currentlyExcluded =
                state.narrationOutline.first { $0.chapterIndex == chapterIndex }?.isExcluded
                ?? false
            let service = AlignmentService(db: db, audiobookID: audiobookID)
            do {
                if currentlyExcluded {
                    try service.unhideChapter(chapterIndex: chapterIndex)
                } else {
                    try service.hideChapter(
                        chapterIndex: chapterIndex, reason: "Excluded from narration")
                }
            } catch {
                return
            }
            if !currentlyExcluded {
                let fileName = NarrationFileNaming.chapterFileName(
                    audiobookID: audiobookID, chapterIndex: chapterIndex,
                    voice: narrationVoiceForFiles)
                if let removeAt = state.tracks.firstIndex(where: {
                    $0.url.lastPathComponent == fileName
                }), removeAt != state.currentIndex {
                    state.tracks.remove(at: removeAt)
                    if removeAt < state.currentIndex { state.currentIndex -= 1 }
                }
            }
            refreshNarrationOutline()
        }

        /// App-owned, durable location for rendered narration audio. The body now
        /// lives in the cross-platform `NarrationCache` (so the macOS batch queue can
        /// write to the same place); this forwarder keeps the existing iOS call sites
        /// working unchanged.
        static func narrationCacheDirectory() -> URL {
            NarrationCache.directory()
        }
    }

#endif
