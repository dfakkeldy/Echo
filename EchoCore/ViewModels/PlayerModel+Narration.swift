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

        func handleNarrationPreparationProgress(
            _ progress: NarrationPrepareProgress,
            operation: NarrationOperationToken,
            audiobookID: String
        ) {
            guard NarrationRenderPolicy.callbackIsCurrent(
                operation: operation,
                currentOperation: narrationOperation,
                currentFolderURL: bookIdentityURL?.absoluteString,
                audiobookID: audiobookID)
            else { return }

            switch progress {
            case .downloadingModels(let fraction):
                narrationPlaybackState.update(
                    phase: .preparingEngine, progress: 0.5 * fraction,
                    statusMessage:
                        "Downloading voice models… \(Int(min(max(fraction, 0), 1) * 100))%"
                )
            case .compilingModels(let done, let total):
                let fraction = total > 0 ? Double(done) / Double(total) : 0
                narrationPlaybackState.update(
                    phase: .preparingEngine, progress: 0.5 + 0.5 * fraction,
                    statusMessage: "Loading voice models… \(done) of \(total)")
            case .ready:
                narrationPlaybackState.update(
                    phase: .preparingEngine, progress: 1.0,
                    statusMessage: "Voice models ready")
            }
        }

        func handleNarrationBlockProgress(
            chapterDisplayNumber: Int,
            fraction: Double,
            operation: NarrationOperationToken,
            audiobookID: String
        ) {
            guard NarrationRenderPolicy.callbackIsCurrent(
                operation: operation,
                currentOperation: narrationOperation,
                currentFolderURL: bookIdentityURL?.absoluteString,
                audiobookID: audiobookID)
            else { return }

            state.currentSubtitle = NarrationProgressText.subtitle(
                chapterDisplayNumber: chapterDisplayNumber, fraction: fraction)
            // This callback only fires while the chapter is still rendering
            // (render-then-play), so no audio is playing yet.
            progressPresenter.updateNowPlayingInfo(isPaused: true)
        }

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
            guard let audiobookID = bookIdentityURL?.absoluteString,
                let db = databaseService?.writer
            else { return }

            narrationRenderTask?.cancel()
            let operation = replaceNarrationOperation()
            narrationPlaybackState.reset()
            state.narrationRenderInFlight = true
            state.awaitingNarrationChapter = false
            state.narrationDefaultVoice = nil
            state.narrationVoiceOverrideCount = 0
            narrationExpectedFileNamesByChapter = [:]

            // Stop playback before plan-aware cache eviction so the AVPlayer isn't
            // holding a reference to a file we're about to delete (§5.1).
            playbackController.stop()

            // Show the book + a preparing status on Now Playing / lock screen while
            // the first chapter renders, instead of the audio-less placeholder.
            if state.currentTitle.isEmpty,
                let identityURL = bookIdentityURL ?? state.sourceDocumentURL ?? folderURL
            {
                state.currentTitle = identityURL.deletingPathExtension().lastPathComponent
            }
            state.currentSubtitle = String(localized: "Preparing narration…")
            progressPresenter.updateNowPlayingInfo(isPaused: true)

            let cacheDirectory = Self.narrationCacheDirectory()
            narrationRenderTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Wait for loadFolder's no-audio EPUB import to finish so a
                    // first-ever open isn't read before its blocks are committed.
                    await self.playerLoadingCoordinator.documentImportTask?.value
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)
                    let blockDAO = EPubBlockDAO(db: db)
                    let allBlocks = try blockDAO.allBlocks(for: audiobookID)
                    // Visible blocks omit chapters marked "Not in Audio", matching
                    // the alignment/timeline paths. The complete set remains the
                    // presentation source for the excluded-chapter outline.
                    let visibleBlocks = try blockDAO.visibleBlocks(for: audiobookID)
                    let chapters = NarrationChapterPlanner.plan(from: visibleBlocks)
                    let allChapters = NarrationChapterPlanner.plan(from: allBlocks)
                    guard !chapters.isEmpty else {
                        self.state.narrationRenderInFlight = false
                        self.state.currentSubtitle = String(localized: "No text to narrate")
                        self.progressPresenter.updateNowPlayingInfo(isPaused: true)
                        return
                    }

                    let pronunciationPack = await EnglishPronunciationPack.bundledOrEmpty()
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)
                    let service = NarrationService(
                        db: db, audiobookID: audiobookID, tts: narrationTTS,
                        audioWriter: AVFoundationAudioWriter(), cacheDirectory: cacheDirectory,
                        state: narrationPlaybackState,
                        pronunciationOverrides: {
                            PronunciationOverrideStore.shared.overrides(
                                forBookID: audiobookID)
                        },
                        pronunciationOccurrenceOverrides: {
                            PronunciationOverrideStore.shared.occurrenceOverrides(
                                forBookID: audiobookID)
                        },
                        pronunciationPack: pronunciationPack)
                    let existingFileNames = Set(
                        (try? FileManager.default.contentsOfDirectory(
                            atPath: cacheDirectory.path)) ?? [])
                    let preparation = try await NarrationPlaybackPlanPreparation.prepare(
                        chapters: chapters,
                        allChapters: allChapters,
                        preferredVoice: voice.id,
                        resolveManifest: {
                            try AnthologyNarrationManifestResolver(db: db).resolve(
                                audiobookID: audiobookID,
                                epubURL: self.state.sourceDocumentURL)
                        },
                        existingDurableFileNames: existingFileNames,
                        expectedFileName: { segment in
                            await service.segmentCacheURL(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice)
                                .lastPathComponent
                        },
                        validateActive: {
                            try NarrationRenderPolicy.checkTaskIsActive(
                                currentFolderURL: self.bookIdentityURL?.absoluteString,
                                audiobookID: audiobookID)
                        },
                        cleanup: { expectedFileNames in
                            let bookPrefix = "\(NarrationFileNaming.safeToken(audiobookID))-"
                            for stale in NarrationCacheStore.staleFiles(
                                Array(existingFileNames),
                                bookPrefix: bookPrefix,
                                expectedDurableFileNames: expectedFileNames)
                            {
                                try? FileManager.default.removeItem(
                                    at: cacheDirectory.appendingPathComponent(stale))
                            }
                        })
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)

                    self.state.narrationDefaultVoice = voice.id
                    self.state.narrationVoiceOverrideCount = preparation.voiceOverrideCount
                    self.narrationExpectedFileNamesByChapter =
                        preparation.expectedFileNamesByChapter
                    self.refreshNarrationOutline(allBlocks: allBlocks)

                    // Write the EPUB's cover into the narration cache so Now Playing
                    // and the lock screen show artwork instead of a placeholder. The
                    // cover is declared in the EPUB's OPF (`<meta name="cover">` /
                    // `properties="cover-image"`), NOT as an inline content image, so
                    // resolve it from the book first — matching the live reader. Only
                    // when the EPUB declares no OPF cover (or isn't reachable) do we
                    // fall back to scanning inline image blocks.
                    let coverLogger = Logger(category: "NarrationCover")
                    let coverBase = cacheDirectory.appendingPathComponent("cover")
                    // Clear any stale cover (any common extension) from a prior run.
                    for ext in ["jpg", "jpeg", "png"] {
                        try? FileManager.default.removeItem(
                            at: coverBase.appendingPathExtension(ext))
                    }
                    if let coverData = EpubCoverResolver.coverData(forAudiobookID: audiobookID) {
                        let ext: String =
                            coverData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
                        let coverDest = coverBase.appendingPathExtension(ext)
                        do {
                            try coverData.write(to: coverDest)
                            coverLogger.info("Wrote OPF cover to \(coverDest.path)")
                        } catch {
                            coverLogger.warning(
                                "Failed to write OPF cover: \(error.localizedDescription)")
                        }
                    } else {
                        // Fallback: the first front-matter (else any) inline image
                        // block. Query ALL image blocks (not just visibleBlocks) since
                        // the cover is front-matter and marked is_hidden during import.
                        let imageBlocks = allBlocks.filter {
                            $0.blockKind == EPubBlockRecord.Kind.image.rawValue
                        }
                        let frontMatterImages = imageBlocks.filter(\.isFrontMatter)
                        let candidates =
                            frontMatterImages.isEmpty ? imageBlocks : frontMatterImages
                        if let coverBlock =
                            candidates
                            .sorted(by: { $0.sequenceIndex < $1.sequenceIndex })
                            .first,
                            let imagePath = coverBlock.imagePath,
                            FileManager.default.fileExists(atPath: imagePath)
                        {
                            let coverSource = URL(fileURLWithPath: imagePath)
                            let ext =
                                coverSource.pathExtension.isEmpty
                                ? "jpg" : coverSource.pathExtension
                            let coverDest = coverBase.appendingPathExtension(ext)
                            try? FileManager.default.removeItem(at: coverDest)
                            do {
                                try FileManager.default.copyItem(at: coverSource, to: coverDest)
                                coverLogger.info("Copied inline cover image to \(coverDest.path)")
                            } catch {
                                coverLogger.warning(
                                    "Failed to copy inline cover image: \(error.localizedDescription)"
                                )
                            }
                        } else {
                            coverLogger.debug(
                                "No cover found (no OPF cover, no inline image block)")
                        }
                    }

                    let segments = preparation.segments
                    let forwardSegments: [NarrationSegmentPlanner.PlannedSegment]
                    let earlierSegments: [NarrationSegmentPlanner.PlannedSegment]
                    let lastTrackURL = self.persistence.getLastTrack(for: audiobookID)
                        .flatMap(URL.init(string:))
                    switch NarrationResumeResolver.target(
                        fromLastTrackURL: lastTrackURL,
                        plans: preparation.chapters,
                        isAnthology: preparation.manifest != nil)
                    {
                    case .sourceChapterKey(let sourceChapterKey):
                        forwardSegments = NarrationSegmentPlanner.resume(
                            segments, startingAtSourceChapterKey: sourceChapterKey)
                        earlierSegments = NarrationSegmentPlanner.beforeResume(
                            segments, startingAtSourceChapterKey: sourceChapterKey)
                    case .chapterIndex(let resumeIndex):
                        forwardSegments = NarrationSegmentPlanner.resume(
                            segments, startingAtChapterIndex: resumeIndex)
                        earlierSegments = NarrationSegmentPlanner.beforeResume(
                            segments, startingAtChapterIndex: resumeIndex)
                    case nil:
                        forwardSegments = segments
                        earlierSegments = []
                    }

                    // Pay the one-time model download + ONNX session load before the
                    // first chapter, reporting real progress so the user sees
                    // "Downloading… %" / "Loading voice models… N of M" instead of a
                    // silent "Preparing narration…" spinner.
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)
                    try await self.narrationTTS.prepare(progress: { [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.handleNarrationPreparationProgress(
                                p, operation: operation, audiobookID: audiobookID)
                        }
                    })
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)

                    let lookAhead = 2
                    for (offset, segment) in forwardSegments.enumerated() {
                        try Task.checkCancellation()

                        let fileURL = await service.segmentCacheURL(
                            chapterIndex: segment.chapterIndex,
                            sourceChapterKey: segment.sourceChapterKey,
                            segmentIndex: segment.segmentIndex,
                            blocks: segment.blocks,
                            voice: segment.voice)
                        try NarrationRenderPolicy.checkTaskIsActive(
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID)

                        // Persistence: a segment already rendered for this voice is
                        // reused as-is. Re-synthesising it would burn seconds of CPU
                        // time + battery + heat per segment and defeat the durable
                        // cache (and make export / per-item narration pointlessly
                        // expensive). So we only render — and only apply look-ahead
                        // backpressure — when the file is actually missing.
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
                            let alreadyRenderedThisChapter = Self.narrationCacheContainsChapter(
                                audiobookID: audiobookID,
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                voice: segment.voice,
                                cacheDirectory: cacheDirectory)
                            guard
                                self.allowNarrationRenderOrPresentPaywall(
                                    audiobookID: audiobookID,
                                    alreadyRenderedThisChapter: alreadyRenderedThisChapter)
                            else { return }
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
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            {
                                try await Task.sleep(for: .seconds(1))
                                try Task.checkCancellation()
                            }
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                            // Lock screen: name the chapter being prepared (the in-app NarrationStatusView
                            // already shows the per-block bar; the lock screen otherwise sits on the stale
                            // "Preparing narration…"). The per-block percent is refreshed in the cover
                            // callback below.
                            self.state.currentSubtitle = NarrationProgressText.subtitle(
                                chapterDisplayNumber: segment.chapterDisplayNumber, fraction: 0)
                            self.progressPresenter.updateNowPlayingInfo(isPaused: true)
                            try await service.renderSegment(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle,
                                onBlockProgress: { [weak self] displayNumber, fraction in
                                    self?.handleNarrationBlockProgress(
                                        chapterDisplayNumber: displayNumber,
                                        fraction: fraction,
                                        operation: operation,
                                        audiobookID: audiobookID)
                                })
                            try Task.checkCancellation()
                            // Bail if the user switched books while this chapter rendered.
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                        } else {
                            try await service.updateCachedNarrationTitle(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle)
                            try NarrationRenderPolicy.checkTaskIsActive(
                                currentFolderURL: self.bookIdentityURL?.absoluteString,
                                audiobookID: audiobookID)
                        }

                        let track = Track(
                            url: fileURL,
                            title: segment.chapterTitle)

                        if offset == 0 {
                            // First segment: start playing through the pipeline.
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
                    for segment in earlierSegments {
                        try Task.checkCancellation()
                        let fileURL = await service.segmentCacheURL(
                            chapterIndex: segment.chapterIndex,
                            sourceChapterKey: segment.sourceChapterKey,
                            segmentIndex: segment.segmentIndex,
                            blocks: segment.blocks,
                            voice: segment.voice)
                        try NarrationRenderPolicy.checkTaskIsActive(
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID)
                        // Reuse an already-rendered segment (persistence) — only
                        // synthesise the ones missing from the cache.
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
                            let alreadyRenderedThisChapter = Self.narrationCacheContainsChapter(
                                audiobookID: audiobookID,
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                voice: segment.voice,
                                cacheDirectory: cacheDirectory)
                            guard
                                self.allowNarrationRenderOrPresentPaywall(
                                    audiobookID: audiobookID,
                                    alreadyRenderedThisChapter: alreadyRenderedThisChapter)
                            else { return }
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                            try await service.renderSegment(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle)
                            try Task.checkCancellation()
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                        } else {
                            try await service.updateCachedNarrationTitle(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle)
                            try NarrationRenderPolicy.checkTaskIsActive(
                                currentFolderURL: self.bookIdentityURL?.absoluteString,
                                audiobookID: audiobookID)
                        }

                        let track = Track(
                            url: fileURL,
                            title: segment.chapterTitle)
                        self.tracks.insert(track, at: 0)
                        // The playing track shifted one slot right; keep currentIndex on it.
                        self.state.currentIndex += 1
                    }

                    // All chapters rendered and queued.
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }
                    self.refreshNarrationOutline(allBlocks: allBlocks)
                    self.state.narrationRenderInFlight = false
                    self.narrationPlaybackState.complete()
                    // Release both ONNX sessions and the grown arena now that every
                    // chapter of this book is rendered/queued (§7.1). The next book
                    // (or a later replay of this one) re-prepares lazily.
                    await self.narrationTTS.unload()
                } catch is CancellationError {
                    // Switched books or stopped — loadFolder resets the flags.
                } catch where error is AnthologyBuildManifestValidationError
                    || error is NarrationChapterRenderPlanError
                {
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID
                        ) == false
                    else { return }
                    self.state.narrationRenderInFlight = false
                    self.narrationPlaybackState.fail(
                        String(
                            localized:
                                "Rebuild this anthology to refresh its narration plan, then try again."
                        ))
                } catch {
                    // Don't stamp a stale failure onto a book the user switched to.
                    guard
                        NarrationRenderPolicy.bookWasSwitched(
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
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

        /// True when playback chrome should be visible/enabled. Imported audio has
        /// concrete tracks; audio-less EPUB narration books can create their tracks
        /// on demand through `play()`.
        var hasPlaybackContent: Bool {
            !state.tracks.isEmpty
                || (isNarrationBook && NarrationCapability.supportsOnDeviceNarration)
        }

        /// The full EPUB chapter outline for the current narration book.
        var narrationOutline: [NarrationOutlineChapter] { state.narrationOutline }

        private static func narrationCacheContainsChapter(
            audiobookID: String,
            chapterIndex: Int,
            sourceChapterKey: String?,
            voice: VoiceID,
            cacheDirectory: URL
        ) -> Bool {
            let prefix = "\(NarrationFileNaming.safeToken(audiobookID))-"
            let suffix = "-\(voice.rawValue)-v\(NarrationFileNaming.renderVersion).m4a"
            let stableToken = sourceChapterKey.map(NarrationFileNaming.stableChapterToken)
            let names =
                (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
            return names.contains { name in
                guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                    let location = NarrationFileNaming.location(fromFileName: name)
                else { return false }
                if let stableToken {
                    return location.stableChapterToken == stableToken
                }
                return location.chapterIndex == chapterIndex
            }
        }

        /// Rebuilds `state.narrationOutline` from the book's EPUB blocks + which
        /// chapter files exist. User-driven (sheet open / narration start / toggle) —
        /// never per rendered chapter, so it doesn't reintroduce O(chapters²) work.
        func refreshNarrationOutline() {
            guard let audiobookID = bookIdentityURL?.absoluteString,
                let db = databaseService?.writer
            else {
                state.narrationOutline = []
                return
            }
            let blocks = (try? EPubBlockDAO(db: db).allBlocks(for: audiobookID)) ?? []
            refreshNarrationOutline(allBlocks: blocks)
        }

        private func refreshNarrationOutline(allBlocks: [EPubBlockRecord]) {
            let cacheDirectory = Self.narrationCacheDirectory()
            let existingFileNames = Set(
                (try? FileManager.default.contentsOfDirectory(
                    atPath: cacheDirectory.path)) ?? [])
            let renderedChapterIndices = NarrationOutlineReadiness.renderedChapterIndices(
                expectedFileNamesByChapter: narrationExpectedFileNamesByChapter,
                existingFileNames: existingFileNames)
            state.narrationOutline = NarrationOutlineBuilder.build(allBlocks: allBlocks) {
                renderedChapterIndices.contains($0)
            }
        }

        /// Toggles whether a chapter is narrated. Excluding hides all its blocks
        /// (dropped from `plan(from: visibleBlocks)` → never synthesized or queued);
        /// including unhides them. A rendered file is left on disk so re-including is
        /// instant. A newly-excluded chapter is pulled from the live queue unless it
        /// is the one currently playing (that finishes; future renders exclude it).
        func toggleNarrationChapterExcluded(chapterIndex: Int) {
            guard let audiobookID = bookIdentityURL?.absoluteString,
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
                let removableIndices = state.tracks.indices.reversed().filter { index in
                    index != state.currentIndex
                        && NarrationFileNaming.chapterIndex(
                            fromFileName: state.tracks[index].url.lastPathComponent) == chapterIndex
                }
                for removeAt in removableIndices {
                    state.tracks.remove(at: removeAt)
                    if removeAt < state.currentIndex { state.currentIndex -= 1 }
                }
            }
            refreshNarrationOutline()
        }

        func allowNarrationRenderOrPresentPaywall(
            audiobookID: String,
            alreadyRenderedThisChapter: Bool
        ) -> Bool {
            guard
                freeTierGate?.canRenderNarration(
                    audiobookID: audiobookID,
                    alreadyRenderedThisChapter: alreadyRenderedThisChapter
                ) == false
            else { return true }

            state.narrationRenderInFlight = false
            state.awaitingNarrationChapter = false
            paywallContext = .narrationCap
            showPaywall = true
            narrationPlaybackState.fail(PaywallContext.narrationCap.subheadline)
            progressPresenter.updateNowPlayingInfo(isPaused: true)
            return false
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
