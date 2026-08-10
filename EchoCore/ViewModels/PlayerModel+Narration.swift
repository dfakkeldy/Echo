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

    /// Bridges the synchronous preparation callback into one ordered consumer.
    /// The consumer is explicitly awaited so preparation cannot complete while
    /// lifecycle updates are still queued on the main actor.
    enum NarrationPreparationProgressRelay {
        static func run(
            prepare: (@escaping @Sendable (NarrationPrepareProgress) -> Void) async throws -> Void,
            receive: @escaping @MainActor @Sendable (NarrationPrepareProgress) async -> Void
        ) async throws {
            let (stream, continuation) = AsyncStream.makeStream(
                of: NarrationPrepareProgress.self,
                bufferingPolicy: .unbounded)
            let consumer = Task { @MainActor in
                for await progress in stream {
                    await receive(progress)
                }
            }

            try await withTaskCancellationHandler {
                do {
                    try await prepare { progress in
                        continuation.yield(progress)
                    }
                    continuation.finish()
                    await consumer.value
                    try Task.checkCancellation()
                } catch {
                    continuation.finish()
                    consumer.cancel()
                    await consumer.value
                    throw error
                }
            } onCancel: {
                continuation.finish()
                consumer.cancel()
            }
        }
    }

    // MARK: - On-device narration playback

    extension PlayerModel {

        var currentNarrationChapterDisplayNumber: Int? {
            guard state.tracks.indices.contains(state.currentIndex) else { return nil }
            let fileName = state.tracks[state.currentIndex].url.lastPathComponent
            return NarrationFileNaming.location(fromFileName: fileName)?.chapterIndex.map {
                $0 + 1
            } ?? (state.currentIndex + 1)
        }

        var currentRenderingChapterDisplayNumber: Int? {
            switch narrationPlaybackState.snapshot.render {
            case .rendering(let unit), .heldByBackpressure(.some(let unit)):
                return unit.chapterDisplayNumber
            default:
                return nil
            }
        }

        func playbackEvent(
            _ message: String,
            severity: NarrationEventDescriptor.Severity
        ) -> NarrationEventDescriptor {
            let activity = message.lowercased()
            let chapterSuffix = currentNarrationChapterDisplayNumber.map {
                " chapter=\($0)"
            } ?? ""
            let renderingChapterSuffix = currentRenderingChapterDisplayNumber.map {
                " renderingChapter=\($0)"
            } ?? ""
            return .init(
                category: .playback,
                severity: severity,
                message: String(localized: String.LocalizationValue(message)),
                developerMessage:
                    "playback \(activity)\(chapterSuffix)\(renderingChapterSuffix)")
        }

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
            case .checkingModel(let expectedBytes):
                narrationPlaybackState.transitionRender(
                    to: .checkingModel(expectedBytes: expectedBytes),
                    event: .init(
                        category: .model, severity: .info,
                        message: String(localized: "Checking narration model"),
                        developerMessage: "model cache check expectedBytes=\(expectedBytes)"))
                publishNarrationStatusToNowPlaying()
            case .modelCacheHit(let byteCount):
                narrationPlaybackState.transitionRender(
                    to: .validatingModel(byteCount: byteCount),
                    event: .init(
                        category: .model, severity: .notice,
                        message: String(localized: "Narration model found in cache"),
                        developerMessage: "model cache hit bytes=\(byteCount)"))
                publishNarrationStatusToNowPlaying()
            case .downloadingModel(let receivedBytes, let totalBytes):
                let publishesMilestone = narrationPlaybackState.reportModelDownload(
                    receivedBytes: receivedBytes, totalBytes: totalBytes)
                if publishesMilestone { publishNarrationStatusToNowPlaying() }
            case .validatingModel(let byteCount):
                narrationPlaybackState.transitionRender(
                    to: .validatingModel(byteCount: byteCount),
                    event: .init(
                        category: .model, severity: .info,
                        message: String(localized: "Validating narration model"),
                        developerMessage: "model validating bytes=\(byteCount)"))
                publishNarrationStatusToNowPlaying()
            case .loadingModel:
                narrationPlaybackState.transitionRender(
                    to: .loadingModel(startedAt: Date()),
                    event: .init(
                        category: .model, severity: .notice,
                        message: String(localized: "Loading narration model"),
                        developerMessage: "model session loading"))
                publishNarrationStatusToNowPlaying()
            case .ready:
                narrationPlaybackState.transitionRender(
                    to: .modelReady,
                    event: .init(
                        category: .model, severity: .notice,
                        message: String(localized: "Narration model ready"),
                        developerMessage: "model session ready"))
                publishNarrationStatusToNowPlaying()
            }
        }

        func publishNarrationStatusToNowPlaying() {
            progressPresenter.updateNowPlayingInfo(isPaused: !isPlaying)
        }

        func recordNarrationPlanPreparation(
            totalSegments: Int,
            voice: NarrationVoice,
            voiceOverrideCount: Int
        ) {
            var buffer = narrationPlaybackState.snapshot.buffer
            buffer.totalSegments = totalSegments
            narrationPlaybackState.updateBuffer(buffer)
            state.narrationDefaultVoice = voice.id
            narrationPlaybackState.record(
                .init(
                    category: .voice, severity: .notice,
                    message: String(localized: "Selected voice: \(voice.displayName)"),
                    developerMessage: "default voice selected id=\(voice.id.rawValue)"))
            state.narrationVoiceOverrideCount = voiceOverrideCount
            narrationPlaybackState.record(
                .init(
                    category: .voice, severity: .info,
                    message: String(localized: "Chapter voice overrides: \(voiceOverrideCount)"),
                    developerMessage: "chapter voice overrides count=\(voiceOverrideCount)"))
        }

        @discardableResult
        func beginNarrationRenderUnit(
            chapterDisplayNumber: Int,
            segmentIndex: Int,
            voiceID: VoiceID,
            totalBlocks: Int,
            at date: Date = Date()
        ) -> NarrationRenderUnitStatus {
            let unit = NarrationRenderUnitStatus(
                chapterDisplayNumber: chapterDisplayNumber,
                segmentIndex: segmentIndex,
                voiceID: voiceID,
                completedBlocks: 0,
                totalBlocks: max(0, totalBlocks),
                startedAt: date,
                lastProgressAt: date)
            let voiceName = VoiceCatalog.voice(for: voiceID)?.displayName ?? voiceID.rawValue
            narrationPlaybackState.transitionRender(
                to: .rendering(unit),
                event: .init(
                    category: .render,
                    severity: .notice,
                    message: String(
                        localized:
                            "Rendering chapter \(chapterDisplayNumber) with \(voiceName)"),
                    developerMessage:
                        "render started chapter=\(chapterDisplayNumber) segment=\(segmentIndex) voiceID=\(voiceID.rawValue) voiceName=\(voiceName) totalBlocks=\(unit.totalBlocks)"),
                at: date)
            publishNarrationStatusToNowPlaying()
            return unit
        }

        func holdNarrationRenderForBackpressure(at date: Date = Date()) {
            if case .heldByBackpressure = narrationPlaybackState.snapshot.render {
                return
            }
            let unit: NarrationRenderUnitStatus?
            if case .rendering(let current) = narrationPlaybackState.snapshot.render {
                unit = current
            } else {
                unit = nil
            }
            narrationPlaybackState.transitionRender(
                to: .heldByBackpressure(unit),
                event: .init(
                    category: .buffer,
                    severity: .info,
                    message: String(
                        localized: "Rendering paused while playback catches up"),
                    developerMessage: "render held by playback backpressure"),
                at: date)
            publishNarrationStatusToNowPlaying()
        }

        func resumeNarrationRenderAfterBackpressure() {
            guard case .heldByBackpressure(let unit?) = narrationPlaybackState.snapshot.render else {
                return
            }
            narrationPlaybackState.transitionRender(to: .rendering(unit), event: nil)
            publishNarrationStatusToNowPlaying()
        }

        func recordNarrationSegmentQueued(
            totalSegments: Int,
            chapterDisplayNumber: Int,
            segmentIndex: Int
        ) {
            let buffer = NarrationBufferStatus(
                totalSegments: totalSegments,
                queuedSegments: tracks.count,
                currentPlaybackIndex: state.currentIndex)
            narrationPlaybackState.updateBuffer(buffer)
            narrationPlaybackState.record(
                .init(
                    category: .buffer,
                    severity: .notice,
                    message: String(
                        localized:
                            "Chapter \(chapterDisplayNumber) added to playback queue"),
                    developerMessage:
                        "buffer queued chapter=\(chapterDisplayNumber) segment=\(segmentIndex) queuedSegments=\(buffer.queuedSegments) totalSegments=\(buffer.totalSegments) currentPlaybackIndex=\(buffer.currentPlaybackIndex) readyAhead=\(buffer.readyAhead)"))
            publishNarrationStatusToNowPlaying()
        }

        func completeNarrationRendering(at date: Date = Date()) {
            narrationPlaybackState.transitionRender(
                to: .complete,
                event: .init(
                    category: .render,
                    severity: .notice,
                    message: String(localized: "All narration rendered"),
                    developerMessage: "render complete"),
                at: date)
            publishNarrationStatusToNowPlaying()
        }

        func handleNarrationBlockProgress(
            _ progress: NarrationRenderProgress,
            operation: NarrationOperationToken,
            audiobookID: String
        ) {
            guard NarrationRenderPolicy.callbackIsCurrent(
                operation: operation,
                currentOperation: narrationOperation,
                currentFolderURL: bookIdentityURL?.absoluteString,
                audiobookID: audiobookID)
            else { return }

            let previousUnit: NarrationRenderUnitStatus?
            switch narrationPlaybackState.snapshot.render {
            case .rendering(let unit), .heldByBackpressure(.some(let unit)):
                previousUnit = unit
            default:
                previousUnit = nil
            }
            let unit = NarrationRenderUnitStatus(
                chapterDisplayNumber: progress.chapterDisplayNumber,
                segmentIndex: progress.segmentIndex,
                voiceID: progress.voiceID,
                completedBlocks: progress.completedBlocks,
                totalBlocks: progress.totalBlocks,
                startedAt: previousUnit?.startedAt ?? progress.timestamp,
                lastProgressAt: progress.timestamp)
            let completedNewBlock = progress.completedBlocks > (previousUnit?.completedBlocks ?? 0)
            let event: NarrationEventDescriptor? = completedNewBlock
                ? .init(
                    category: .render,
                    severity: .info,
                    message: String(
                        localized:
                            "Chapter \(progress.chapterDisplayNumber) · block \(progress.completedBlocks) of \(progress.totalBlocks)"),
                    developerMessage:
                        "render progress chapter=\(progress.chapterDisplayNumber) segment=\(progress.segmentIndex.map(String.init) ?? "chapter") voiceID=\(progress.voiceID.rawValue) completedBlocks=\(progress.completedBlocks) totalBlocks=\(progress.totalBlocks)")
                : nil
            narrationPlaybackState.transitionRender(
                to: .rendering(unit),
                event: event,
                at: progress.timestamp)
            publishNarrationStatusToNowPlaying()
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
            narrationPlaybackState.beginSession(defaultVoiceID: voice.id)
            narrationPlaybackState.transitionRender(
                to: .planning,
                event: .init(
                    category: .preparation, severity: .notice,
                    message: String(localized: "Preparing narration plan"),
                    developerMessage: "preparation planning started"))
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
            publishNarrationStatusToNowPlaying()

            let cacheDirectory = narrationCacheDirectoryProvider()
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
                        let message = String(localized: "No text to narrate")
                        self.state.currentSubtitle = message
                        self.narrationPlaybackState.transitionRender(
                            to: .noNarratableText,
                            event: .init(
                                category: .render,
                                severity: .notice,
                                message: message,
                                developerMessage: "render stopped no narratable text"))
                        self.narrationPlaybackState.transitionPlayback(
                            to: .stopped,
                            event: nil)
                        self.publishNarrationStatusToNowPlaying()
                        return
                    }

                    let pronunciationPack = await EnglishPronunciationPack.bundledOrEmpty()
                    let pronunciationAuditPack = await EnglishPronunciationAuditPack.bundledOrEmpty()
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)
                    let service = NarrationService(
                        db: db, audiobookID: audiobookID, tts: narrationTTS,
                        audioWriter: narrationAudioWriter, cacheDirectory: cacheDirectory,
                        state: narrationPlaybackState,
                        pronunciationOverrides: {
                            PronunciationOverrideStore.shared.overrides(
                                forBookID: audiobookID)
                        },
                        pronunciationOccurrenceOverrides: {
                            PronunciationOverrideStore.shared.occurrenceOverrides(
                                forBookID: audiobookID)
                        },
                        pronunciationPack: pronunciationPack,
                        pronunciationAuditPack: pronunciationAuditPack,
                        neuralEvaluator: { word in
                            try await MiniBARTG2PEngine.shared.evaluate(word: word)
                        })
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

                    self.recordNarrationPlanPreparation(
                        totalSegments: preparation.segments.count,
                        voice: voice,
                        voiceOverrideCount: preparation.voiceOverrideCount)
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
                    // Exact model-delivery / load status instead of a
                    // silent "Preparing narration…" spinner.
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)
                    try await NarrationPreparationProgressRelay.run(
                        prepare: { progress in
                            try await self.narrationTTS.prepare(progress: progress)
                        },
                        receive: { [weak self] progress in
                            self?.handleNarrationPreparationProgress(
                                progress, operation: operation, audiobookID: audiobookID)
                        })
                    try NarrationRenderPolicy.checkTaskIsActive(
                        currentFolderURL: self.bookIdentityURL?.absoluteString,
                        audiobookID: audiobookID)

                    let lookAhead = NarrationRenderPolicy.lookAhead
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

                        let cacheFileExists = FileManager.default.fileExists(
                            atPath: fileURL.path)
                        let reusedCachedNarration: Bool
                        if cacheFileExists {
                            reusedCachedNarration = try await service.updateCachedNarrationTitle(
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
                        } else {
                            reusedCachedNarration = false
                        }

                        // Persistence: a segment already rendered for this voice is
                        // reused as-is. Re-synthesising it would burn seconds of CPU
                        // time + battery + heat per segment and defeat the durable
                        // cache (and make export / per-item narration pointlessly
                        // expensive). So we only render — and only apply look-ahead
                        // backpressure — when the file is actually missing.
                        if !reusedCachedNarration {
                            let alreadyRenderedThisChapter = Self.narrationCacheContainsChapter(
                                audiobookID: audiobookID,
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                voice: segment.voice,
                                cacheDirectory: cacheDirectory) || cacheFileExists
                            guard
                                self.allowNarrationRenderOrPresentPaywall(
                                    audiobookID: audiobookID,
                                    alreadyRenderedThisChapter: alreadyRenderedThisChapter)
                            else { return }
                            self.beginNarrationRenderUnit(
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                voiceID: segment.voice,
                                totalBlocks: segment.blocks.count)
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
                                self.holdNarrationRenderForBackpressure()
                                try await Task.sleep(for: .seconds(1))
                                try Task.checkCancellation()
                            }
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                            self.resumeNarrationRenderAfterBackpressure()
                            let rendered = try await service.renderSegment(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle,
                                onBlockProgress: { [weak self] progress in
                                    self?.handleNarrationBlockProgress(
                                        progress,
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
                            self.narrationPlaybackState.record(
                                .init(
                                    category: .render,
                                    severity: .notice,
                                    message: String(
                                        localized:
                                            "Chapter \(segment.chapterDisplayNumber) ready · \(Int(rendered.duration))s audio"),
                                    developerMessage:
                                        "render ready chapter=\(segment.chapterDisplayNumber) segment=\(segment.segmentIndex) durationSeconds=\(Int(rendered.duration))"))
                        } else {
                            self.narrationPlaybackState.record(
                                .init(
                                    category: .render,
                                    severity: .info,
                                    message: String(
                                        localized:
                                            "Using cached narration for chapter \(segment.chapterDisplayNumber)"),
                                    developerMessage:
                                        "render cache hit chapter=\(segment.chapterDisplayNumber) segment=\(segment.segmentIndex)"))
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
                                self.narrationPlaybackState.transitionPlayback(
                                    to: .resuming(
                                        chapterDisplayNumber: segment.chapterDisplayNumber),
                                    event: .init(
                                        category: .playback,
                                        severity: .notice,
                                        message: String(
                                            localized:
                                                "Chapter \(segment.chapterDisplayNumber) ready · resuming"),
                                        developerMessage:
                                            "playback resuming chapter=\(segment.chapterDisplayNumber)"))
                                self.state.awaitingNarrationChapter = false
                                self.playbackController.nextTrack()
                            }
                        }
                        self.recordNarrationSegmentQueued(
                            totalSegments: segments.count,
                            chapterDisplayNumber: segment.chapterDisplayNumber,
                            segmentIndex: segment.segmentIndex)
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
                        let cacheFileExists = FileManager.default.fileExists(
                            atPath: fileURL.path)
                        let reusedCachedNarration: Bool
                        if cacheFileExists {
                            reusedCachedNarration = try await service.updateCachedNarrationTitle(
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
                        } else {
                            reusedCachedNarration = false
                        }
                        // Reuse an already-rendered segment (persistence) — only
                        // synthesise the ones missing from the cache.
                        if !reusedCachedNarration {
                            let alreadyRenderedThisChapter = Self.narrationCacheContainsChapter(
                                audiobookID: audiobookID,
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                voice: segment.voice,
                                cacheDirectory: cacheDirectory) || cacheFileExists
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
                            self.beginNarrationRenderUnit(
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                voiceID: segment.voice,
                                totalBlocks: segment.blocks.count)
                            let rendered = try await service.renderSegment(
                                chapterIndex: segment.chapterIndex,
                                sourceChapterKey: segment.sourceChapterKey,
                                chapterDisplayNumber: segment.chapterDisplayNumber,
                                segmentIndex: segment.segmentIndex,
                                blocks: segment.blocks,
                                voice: segment.voice,
                                chapterTitle: segment.chapterTitle,
                                onBlockProgress: { [weak self] progress in
                                    self?.handleNarrationBlockProgress(
                                        progress,
                                        operation: operation,
                                        audiobookID: audiobookID)
                                })
                            try Task.checkCancellation()
                            guard
                                NarrationRenderPolicy.bookWasSwitched(
                                    currentFolderURL: self.bookIdentityURL?.absoluteString,
                                    audiobookID: audiobookID
                                ) == false
                            else { return }
                            self.narrationPlaybackState.record(
                                .init(
                                    category: .render,
                                    severity: .notice,
                                    message: String(
                                        localized:
                                            "Chapter \(segment.chapterDisplayNumber) ready · \(Int(rendered.duration))s audio"),
                                    developerMessage:
                                        "render ready chapter=\(segment.chapterDisplayNumber) segment=\(segment.segmentIndex) durationSeconds=\(Int(rendered.duration))"))
                        } else {
                            self.narrationPlaybackState.record(
                                .init(
                                    category: .render,
                                    severity: .info,
                                    message: String(
                                        localized:
                                            "Using cached narration for chapter \(segment.chapterDisplayNumber)"),
                                    developerMessage:
                                        "render cache hit chapter=\(segment.chapterDisplayNumber) segment=\(segment.segmentIndex)"))
                        }

                        let track = Track(
                            url: fileURL,
                            title: segment.chapterTitle)
                        self.tracks.insert(track, at: 0)
                        // The playing track shifted one slot right; keep currentIndex on it.
                        self.state.currentIndex += 1
                        self.recordNarrationSegmentQueued(
                            totalSegments: segments.count,
                            chapterDisplayNumber: segment.chapterDisplayNumber,
                            segmentIndex: segment.segmentIndex)
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
                    self.completeNarrationRendering()
                    // Release both ONNX sessions and the grown arena now that every
                    // chapter of this book is rendered/queued (§7.1). The next book
                    // (or a later replay of this one) re-prepares lazily.
                    await self.narrationTTS.unload()
                } catch is CancellationError {
                    guard
                        NarrationRenderPolicy.callbackIsCurrent(
                            operation: operation,
                            currentOperation: self.narrationOperation,
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID)
                    else { return }
                    self.state.narrationRenderInFlight = false
                    self.narrationPlaybackState.transitionRender(
                        to: .cancelled,
                        event: .init(
                            category: .render,
                            severity: .notice,
                            message: String(localized: "Narration cancelled"),
                            developerMessage: "render cancelled"))
                    self.publishNarrationStatusToNowPlaying()
                } catch where error is AnthologyBuildManifestValidationError
                    || error is NarrationChapterRenderPlanError
                {
                    guard
                        NarrationRenderPolicy.callbackIsCurrent(
                            operation: operation,
                            currentOperation: self.narrationOperation,
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID)
                    else { return }
                    self.state.narrationRenderInFlight = false
                    let message = String(
                        localized:
                            "Rebuild this anthology to refresh its narration plan, then try again."
                    )
                    self.narrationPlaybackState.transitionRender(
                        to: .failed(message: message),
                        event: .init(
                            category: .error,
                            severity: .error,
                            message: message,
                            developerMessage: "render failed type=plan-validation"))
                    self.publishNarrationStatusToNowPlaying()
                } catch {
                    // Don't stamp a stale failure onto a replacement render or book.
                    guard
                        NarrationRenderPolicy.callbackIsCurrent(
                            operation: operation,
                            currentOperation: self.narrationOperation,
                            currentFolderURL: self.bookIdentityURL?.absoluteString,
                            audiobookID: audiobookID)
                    else { return }
                    self.state.narrationRenderInFlight = false
                    let message = error.localizedDescription
                    self.narrationPlaybackState.transitionRender(
                        to: .failed(message: message),
                        event: .init(
                            category: .error,
                            severity: .error,
                            message: message,
                            developerMessage:
                                "render failed type=\(String(reflecting: type(of: error)))",
                            privateDetail: message))
                    self.publishNarrationStatusToNowPlaying()
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
                narrationCachePath: narrationCacheDirectoryProvider().path)
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
            let cacheDirectory = narrationCacheDirectoryProvider()
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
                let removableIndices = NarrationOutlineReadiness.removableQueueIndices(
                    fileNames: state.tracks.map { $0.url.lastPathComponent },
                    currentIndex: state.currentIndex,
                    expectedFileNames: narrationExpectedFileNamesByChapter[chapterIndex] ?? [])
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
            let message = String(
                localized: String.LocalizationValue(PaywallContext.narrationCap.subheadline))
            narrationPlaybackState.transitionRender(
                to: .blocked(message: message),
                event: .init(
                    category: .error,
                    severity: .warning,
                    message: message,
                    developerMessage: "render blocked by narration entitlement"))
            narrationPlaybackState.transitionPlayback(to: .stopped, event: nil)
            publishNarrationStatusToNowPlaying()
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
