// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import os.log

enum NarrationError: Error, Equatable {
    case synthesisFailed
    case audiobookNotFound
    /// A single sub-chunk exceeded the model's input length cap. Surfaced so a
    /// test double can exercise the "skip this sub-chunk, keep the chapter" path;
    /// the ONNX engine raises it when a chunk can't be synthesized within bounds.
    case lengthCapExceeded
    /// A CoreML model package failed to download/verify from Hugging Face.
    /// `underlying` is the transport error (or nil on a non-2xx HTTP status);
    /// kept optional + not compared for `Equatable` since the underlying error
    /// is not itself `Equatable`.
    case modelDownloadFailed(name: String, underlying: Error?)
    /// The narration engine was asked to synthesize before `prepare()` succeeded.
    case engineUnavailable

    static func == (lhs: NarrationError, rhs: NarrationError) -> Bool {
        switch (lhs, rhs) {
        case (.synthesisFailed, .synthesisFailed),
            (.audiobookNotFound, .audiobookNotFound),
            (.lengthCapExceeded, .lengthCapExceeded),
            (.engineUnavailable, .engineUnavailable):
            return true
        case (.modelDownloadFailed(let l, _), .modelDownloadFailed(let r, _)):
            return l == r
        default:
            return false
        }
    }
}

/// Renders narration one chapter at a time (render-then-play): synthesize each
/// block → write one AAC file → insert a TrackRecord + one `.synthesized`
/// AlignmentAnchorRecord per text block. Mirrors AutoAlignmentService.
@MainActor @Observable
final class NarrationService {
    private let logger = Logger(category: "Narration")
    /// Trailing silence appended to every rendered chapter so the final word
    /// isn't clipped when the player advances to the next chapter. Kokoro ends a
    /// chunk right on the last phoneme (no ring-out) and the gapless engine
    /// schedules the next track a hair before `duration` elapses; padding the
    /// file closes both gaps. Exposed `static` so the render-duration test can
    /// assert the exact padded length. ~0.75 s ≈ 0.4 s of dead air even at 2×.
    nonisolated static let leadOutPadSeconds: TimeInterval = 0.75
    /// Shared, reused across renders — allocating an `ISO8601DateFormatter` per
    /// `renderChapter` call is wasteful (§7.2). `@MainActor`-isolated via the
    /// class, so there's no Sendable concern around the non-Sendable formatter.
    private static let iso8601 = ISO8601DateFormatter()
    private let db: DatabaseWriter
    private let audiobookID: String
    let tts: TTSEngine
    private let audioWriter: AudioFileWriting
    private let cacheDirectory: URL
    let state: NarrationState
    private let fmEnabledProvider: () -> Bool
    /// Session-scoped cache for FM-normalized text. One instance per narration
    /// run so the same paragraph is only FM-processed once, even across chapters
    /// and voices. FM-unavailable or FM-makes-no-changes → passthrough (no-op).
    private let fmCache = FMNormalizationCache()

    /// Whether FM pre-normalization is enabled for this narration run.
    /// Respects the `narrationQAClassifier` UserDefaults key: when set to
    /// "deterministic", FM is off for both QA and pre-normalization.
    private var fmEnabled: Bool {
        fmEnabledProvider()
    }

    /// Supplies the user pronunciation overrides applied to each block's text
    /// after `TextNormalizer` and before chunking/synthesis. Evaluated as a
    /// closure (not a stored value) so the live `PronunciationOverrideStore` is
    /// read at render time; defaults to an empty map, so callers and tests that
    /// don't pass one are unaffected by the feature.
    private let pronunciationOverrides: () -> PronunciationOverrides
    /// Supplies source-position pronunciation overrides accepted from narration QA.
    /// Read at render time for the same reason as the word dictionary above.
    private let pronunciationOccurrenceOverrides: () -> PronunciationOccurrenceOverrides

    init(
        db: DatabaseWriter, audiobookID: String, tts: TTSEngine,
        audioWriter: AudioFileWriting, cacheDirectory: URL, state: NarrationState,
        pronunciationOverrides: @escaping () -> PronunciationOverrides = {
            PronunciationOverrides(entries: [:])
        },
        pronunciationOccurrenceOverrides: @escaping () -> PronunciationOccurrenceOverrides = {
            .empty
        },
        fmEnabled: @escaping () -> Bool = {
            UserDefaults.standard.string(forKey: "narrationQAClassifier") ?? "auto" == "auto"
        }
    ) {
        self.db = db
        self.audiobookID = audiobookID
        self.tts = tts
        self.audioWriter = audioWriter
        self.cacheDirectory = cacheDirectory
        self.state = state
        self.pronunciationOverrides = pronunciationOverrides
        self.pronunciationOccurrenceOverrides = pronunciationOccurrenceOverrides
        self.fmEnabledProvider = fmEnabled
    }

    struct RenderedNarrationFile: Sendable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let segmentIndex: Int?
        let fileURL: URL
        let duration: TimeInterval
        let anchors: [AlignmentAnchorRecord]
        let spokenBlockIDs: [String]
        /// Per-block synthesized speech ranges captured from the render stream.
        /// These ranges exclude planned silence so generated read-along rows do
        /// not stretch words through intentional pauses.
        let speechRangesByBlock: [String: [NarrationSpeechRange]]
        /// Per-block file-relative word timings captured at synthesis (empty when
        /// the engine emitted none). Applied over the interpolated baseline.
        let synthesisWordTimingsByBlock: [String: [ChunkWordTiming]]
        /// OOV fallback words encountered while synthesizing this render unit.
        let pronunciationFallbackHits: [RenderedPronunciationFallbackHit]

        init(
            chapterIndex: Int,
            chapterDisplayNumber: Int,
            segmentIndex: Int?,
            fileURL: URL,
            duration: TimeInterval,
            anchors: [AlignmentAnchorRecord],
            spokenBlockIDs: [String],
            speechRangesByBlock: [String: [NarrationSpeechRange]] = [:],
            synthesisWordTimingsByBlock: [String: [ChunkWordTiming]],
            pronunciationFallbackHits: [RenderedPronunciationFallbackHit] = []
        ) {
            self.chapterIndex = chapterIndex
            self.chapterDisplayNumber = chapterDisplayNumber
            self.segmentIndex = segmentIndex
            self.fileURL = fileURL
            self.duration = duration
            self.anchors = anchors
            self.spokenBlockIDs = spokenBlockIDs
            self.speechRangesByBlock = speechRangesByBlock
            self.synthesisWordTimingsByBlock = synthesisWordTimingsByBlock
            self.pronunciationFallbackHits = pronunciationFallbackHits
        }
    }

    func chapterCacheURL(
        chapterIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID
    ) async -> URL {
        chapterCacheURL(
            chapterIndex: chapterIndex,
            blocks: blocks,
            voice: voice,
            overrides: pronunciationOverrides(),
            occurrenceOverrides: pronunciationOccurrenceOverrides(),
            normalizationMode: normalizationMode(fmEnabled: fmEnabled))
    }

    func segmentCacheURL(
        chapterIndex: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID
    ) async -> URL {
        segmentCacheURL(
            chapterIndex: chapterIndex,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            overrides: pronunciationOverrides(),
            occurrenceOverrides: pronunciationOccurrenceOverrides(),
            normalizationMode: normalizationMode(fmEnabled: fmEnabled))
    }

    private func chapterCacheURL(
        chapterIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String
    ) -> URL {
        let signature = contentSignature(
            for: blocks,
            includeLeadOutPad: true,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode)
        return cacheDirectory.appendingPathComponent(
            NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                voice: voice,
                contentSignature: signature))
    }

    private func segmentCacheURL(
        chapterIndex: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String
    ) -> URL {
        let signature = contentSignature(
            for: blocks,
            includeLeadOutPad: false,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode)
        return cacheDirectory.appendingPathComponent(
            NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                segmentIndex: segmentIndex,
                voice: voice,
                contentSignature: signature))
    }

    private func contentSignature(
        for blocks: [EPubBlockRecord],
        includeLeadOutPad: Bool,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        normalizationMode: String
    ) -> String {
        let spoken = blocks.filter { $0.text?.isEmpty == false }
        var renderedTexts: [String] = []
        renderedTexts.reserveCapacity(spoken.count)
        for block in spoken {
            let normalized = TextNormalizer.normalize(block.text ?? "")
            renderedTexts.append(
                Self.renderedText(
                    fromNormalized: normalized,
                    blockID: block.id,
                    overrides: overrides,
                    occurrenceOverrides: occurrenceOverrides))
        }
        return NarrationFileNaming.contentSignature(
            spokenBlocks: spoken,
            renderedTexts: renderedTexts,
            includeLeadOutPad: includeLeadOutPad,
            normalizationMode: normalizationMode)
    }

    private static func renderedText(
        fromNormalized normalized: String,
        blockID: String,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides
    ) -> String {
        let occurrenceSpecific = occurrenceOverrides.apply(to: normalized, blockID: blockID)
        return HomographPronunciationResolver.apply(to: overrides.apply(to: occurrenceSpecific))
    }

    private func normalizationMode(fmEnabled: Bool) -> String {
        fmEnabled ? "fm-auto-v\(FMNormalizer.signatureVersion)" : "deterministic"
    }

    private func partialCacheURL(for fileURL: URL) -> URL {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let partialName = ".\(baseName).partial"
        let directory = fileURL.deletingLastPathComponent()
        let partialURL = directory.appendingPathComponent(partialName)
        let pathExtension = fileURL.pathExtension
        return pathExtension.isEmpty ? partialURL : partialURL.appendingPathExtension(pathExtension)
    }

    /// Render one chapter. Cancellable between blocks; on cancel, nothing is persisted.
    /// Idempotent: re-rendering the same chapter (e.g. a voice change) upserts in place.
    ///
    /// `chapterIndex` is the raw EPUB index — it keys the cache file, the track id,
    /// and sort order, and must stay stable. `chapterNumber` is the human-facing
    /// 1-based position among *narratable* chapters (front matter excluded), used
    /// only for the title and status text so the first real chapter reads
    /// "Chapter 1". Defaults to `chapterIndex + 1` when omitted (tests that don't
    /// exercise numbering).
    func renderChapter(
        chapterIndex: Int, chapterNumber: Int? = nil,
        blocks: [EPubBlockRecord], voice: VoiceID,
        chapterTitle: String? = nil,
        onBlockProgress: (@MainActor (_ chapterDisplayNumber: Int, _ fraction: Double) -> Void)? =
            nil
    ) async throws {
        let displayNumber = chapterNumber ?? (chapterIndex + 1)
        let savedTitle = Self.savedTitle(
            displayNumber: displayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let chapterStart = Date()
        let overrides = pronunciationOverrides()
        let occurrenceOverrides = pronunciationOccurrenceOverrides()
        let fmEnabled = fmEnabled
        let fileURL = chapterCacheURL(
            chapterIndex: chapterIndex,
            blocks: blocks,
            voice: voice,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode(fmEnabled: fmEnabled))
        let rendered = try await renderNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: displayNumber,
            segmentIndex: nil,
            blocks: blocks,
            voice: voice,
            fileURL: fileURL,
            includeLeadOutPad: true,
            reportsProgress: true,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled,
            onBlockProgress: onBlockProgress)
        try await persistRenderedNarration(
            rendered,
            trackID: "syn-\(audiobookID)-ch\(chapterIndex)",
            title: savedTitle,
            sortOrder: chapterIndex,
            voice: voice)

        state.renderedChapterCount += 1
        logger.notice(
            "Chapter \(displayNumber) rendered: \(rendered.anchors.count) anchors, ~\(Int(rendered.duration))s audio, in \(Int(Date().timeIntervalSince(chapterStart)))s."
        )
    }

    /// Render and persist one segment as a playable synthesized track. Anchors
    /// remain segment-local (0-based) and the matching timeline rows are stamped
    /// with `segment_key` so read-along can disambiguate same-chapter time
    /// collisions when segment files are eventually queued for playback.
    func renderSegment(
        chapterIndex: Int,
        chapterDisplayNumber: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        chapterTitle: String? = nil,
        onBlockProgress: (@MainActor (_ chapterDisplayNumber: Int, _ fraction: Double) -> Void)? =
            nil
    ) async throws {
        let savedTitle = Self.savedTitle(
            displayNumber: chapterDisplayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let rendered = try await renderSegmentFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            onBlockProgress: onBlockProgress)

        try await persistRenderedNarration(
            rendered,
            trackID: "syn-\(audiobookID)-ch\(chapterIndex)-s\(segmentIndex)",
            title: savedTitle,
            sortOrder: chapterIndex * 1000 + segmentIndex,
            voice: voice,
            segmentKey: ReaderActiveBlockResolver.segmentKey(
                forChapter: chapterIndex,
                segment: segmentIndex))
    }

    func updateCachedNarrationTitle(
        chapterIndex: Int,
        chapterDisplayNumber: Int,
        segmentIndex: Int? = nil,
        blocks: [EPubBlockRecord],
        chapterTitle: String? = nil
    ) async throws {
        let savedTitle = Self.savedTitle(
            displayNumber: chapterDisplayNumber, blocks: blocks, chapterTitle: chapterTitle)
        let trackID: String
        if let segmentIndex {
            trackID = "syn-\(audiobookID)-ch\(chapterIndex)-s\(segmentIndex)"
        } else {
            trackID = "syn-\(audiobookID)-ch\(chapterIndex)"
        }

        try await db.write { db in
            try db.execute(
                sql: "UPDATE track SET title = ? WHERE id = ? AND audiobook_id = ?",
                arguments: [savedTitle, trackID, audiobookID])
        }
    }

    /// Render one complete segment file without mutating playback, alignment, or
    /// chapter-render state. This is the safe primitive for the hybrid streaming
    /// path: orchestration can prove segment files first, then opt into track,
    /// read-along, and export semantics in later slices.
    func renderSegmentFile(
        chapterIndex: Int,
        chapterDisplayNumber: Int,
        segmentIndex: Int,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        onBlockProgress: (@MainActor (_ chapterDisplayNumber: Int, _ fraction: Double) -> Void)? =
            nil
    ) async throws -> RenderedNarrationFile {
        let overrides = pronunciationOverrides()
        let occurrenceOverrides = pronunciationOccurrenceOverrides()
        let fmEnabled = fmEnabled
        let fileURL = segmentCacheURL(
            chapterIndex: chapterIndex,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            normalizationMode: normalizationMode(fmEnabled: fmEnabled))
        return try await renderNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            blocks: blocks,
            voice: voice,
            fileURL: fileURL,
            includeLeadOutPad: false,
            reportsProgress: false,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled,
            onBlockProgress: onBlockProgress)
    }

    private func persistRenderedNarration(
        _ rendered: RenderedNarrationFile,
        trackID: String,
        title: String,
        sortOrder: Int,
        voice: VoiceID,
        segmentKey: String? = nil
    ) async throws {
        try Task.checkCancellation()  // last gate before any DB write

        let track = TrackRecord(
            id: trackID,
            audiobookID: audiobookID,
            title: title,
            duration: rendered.duration,
            filePath: rendered.fileURL.path,
            isEnabled: true,
            sortOrder: sortOrder,
            playlistPosition: nil,
            narrationVoice: voice.rawValue)

        // One atomic, idempotent transaction off the main thread: upsert the track
        // + every anchor so a re-render (e.g. a voice change) updates in place
        // instead of throwing on a duplicate primary key, and a failure can't
        // leave a half-written render unit.
        let anchorsToSave = rendered.anchors
        try await db.write { db in
            var savedTrack = track
            try savedTrack.save(db)
            for var anchor in anchorsToSave { try anchor.save(db) }
        }

        // Propagate the just-saved `.synthesized` anchors into `timeline_item`:
        // that table — not `alignment_anchor` — is what the reader reads
        // (`WHERE audio_start_time >= 0`), so without this the reader shows no
        // timestamps and never highlights. Runs AFTER the anchor transaction
        // (recalc opens its own `db.write`, so it must not be nested). A recalc
        // failure must not fail the render — the audio is already on disk and the
        // anchors persisted; log and continue.
        do {
            try PronunciationFallbackDiscovery.persist(
                audiobookID: audiobookID,
                hits: rendered.pronunciationFallbackHits,
                createdAt: Self.iso8601.string(from: Date()),
                db: db)
        } catch {
            logger.error(
                "Pronunciation fallback discovery failed: \(error.localizedDescription)"
            )
        }

        do {
            // `anchoredOnly`: only rendered blocks are anchored, so the global
            // synthetic-boundary + interpolation pass must be skipped — otherwise
            // un-narrated front matter gets a near-zero interpolated
            // `audio_start_time`, passes the reader's `>= 0` filter, and the
            // reader highlights front matter instead of the narrated unit.
            //
            // `materializeWordTimings: false`: the default would wipe & rebuild the
            // WHOLE book's `word_timing` table here — run once per render unit is
            // O(chapters²) over a render run. Instead we materialize just this
            // unit's words below, so per-word read-along lights up incrementally.
            try AlignmentService(db: db, audiobookID: audiobookID)
                .recalculateTimeline(anchoredOnly: true, materializeWordTimings: false)
            if rendered.speechRangesByBlock.isEmpty {
                try WordTimingMaterializer.materializeChapter(
                    audiobookID: audiobookID, blockIDs: rendered.spokenBlockIDs, writer: db)
            } else {
                try WordTimingMaterializer.materializeSynthesizedChapter(
                    audiobookID: audiobookID,
                    speechRangesByBlock: rendered.speechRangesByBlock,
                    writer: db)
            }
            let overridden = try WordTimingMaterializer.refineWithSynthesis(
                audiobookID: audiobookID,
                synthesisByBlock: rendered.synthesisWordTimingsByBlock,
                writer: db)
            if !rendered.synthesisWordTimingsByBlock.isEmpty {
                logger.notice(
                    "Synthesis word timing: \(overridden, privacy: .public)/\(rendered.synthesisWordTimingsByBlock.count, privacy: .public) blocks overrode interpolation (rest fell back)."
                )
            }
            if let segmentKey {
                let audioEndTimesByBlockID = Dictionary(
                    uniqueKeysWithValues: rendered.anchors.compactMap { anchor in
                        anchor.audioEndTime.map { (anchor.epubBlockID, $0) }
                    })
                try TimelineDAO(db: db).setSegmentKey(
                    audiobookID: audiobookID,
                    blockIDs: rendered.spokenBlockIDs,
                    segmentKey: segmentKey,
                    audioEndTimesByBlockID: audioEndTimesByBlockID)
                try TimelineDAO(db: db).restoreSegmentAudioEndTimesFromAnchors(
                    audiobookID: audiobookID)
            }
        } catch {
            let unitLabel =
                rendered.segmentIndex.map {
                    "chapter \(rendered.chapterIndex) segment \($0)"
                } ?? "chapter \(rendered.chapterIndex)"
            logger.error(
                "Timeline recalc after \(unitLabel) failed: \(error.localizedDescription)"
            )
        }

        // Tell the reader to reload so the newly-materialized timeline rows
        // light up read-along incrementally as each render unit lands. Mirrors
        // EPUBAutoImportScanner's post; the reader gates on the audiobookID.
        NotificationCenter.default.post(
            name: .timelineItemsIngested,
            object: nil,
            userInfo: ["audiobookID": audiobookID]
        )
    }

    private static func savedTitle(
        displayNumber: Int,
        blocks: [EPubBlockRecord],
        chapterTitle: String?
    ) -> String {
        let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return NarrationChapterPlanner.title(displayNumber: displayNumber, blocks: blocks)
        }
        return title
    }

    private func renderNarrationFile(
        chapterIndex: Int,
        chapterDisplayNumber: Int,
        segmentIndex: Int?,
        blocks: [EPubBlockRecord],
        voice: VoiceID,
        fileURL: URL,
        includeLeadOutPad: Bool,
        reportsProgress: Bool,
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool,
        onBlockProgress: (@MainActor (_ chapterDisplayNumber: Int, _ fraction: Double) -> Void)?
    ) async throws -> RenderedNarrationFile {
        if reportsProgress {
            state.update(
                phase: .preparingChapter, progress: 0,
                statusMessage: "Preparing chapter \(chapterDisplayNumber)…")
        }

        let plan = await renderPlan(
            for: blocks,
            overrides: overrides,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled)
        let speakableBlockIDs = plan.blocks.filter(\.isSpeakable).map(\.blockID)
        var renderedSpeakableBlocks = 0
        let unitLabel =
            segmentIndex.map {
                "Chapter \(chapterDisplayNumber) segment \($0 + 1)"
            } ?? "Chapter \(chapterDisplayNumber)"
        logger.notice("\(unitLabel): synthesizing \(speakableBlockIDs.count) block(s)…")
        var anchors: [AlignmentAnchorRecord] = []
        var spokenBlockIDs: [String] = []
        var speechRangesByBlock: [String: [NarrationSpeechRange]] = [:]
        var synthesisWordTimingsByBlock: [String: [ChunkWordTiming]] = [:]
        var pronunciationFallbackHits: [RenderedPronunciationFallbackHit] = []
        var cursor: TimeInterval = 0
        let now = Self.iso8601.string(from: Date())

        // Stream-to-sink: encode each synthesized sub-chunk straight to a hidden
        // sibling partial, then publish the durable cache file only after finalize()
        // succeeds. The partial keeps an .m4a extension for AVFoundation, while
        // its non-canonical name keeps playback/export from reusing it.
        let partialURL = partialCacheURL(for: fileURL)
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL)
        var didPublishFinalFile = false
        let stream = try audioWriter.makeStream(to: partialURL, sampleRate: 24_000)
        defer {
            if !didPublishFinalFile {
                try? fm.removeItem(at: partialURL)
            }
        }

        for plannedBlock in plan.blocks {
            try Task.checkCancellation()
            let block = plannedBlock.originalBlock

            // Bound each synthesize call under Kokoro's ~510-phoneme context window
            // (see NarrationTextChunker for the budget). One anchor per ORIGINAL
            // block (keyed on block.id) is preserved by spanning the summed sub-chunk
            // durations, so read-along is unchanged regardless of how it sub-chunks.
            var blockDuration: TimeInterval = 0
            var timing = NarrationSynthesisTiming(blockID: plannedBlock.blockID, blockStart: cursor)
            var blockChunkTimings: [(timings: [ChunkWordTiming]?, startInFile: TimeInterval)] = []
            for subText in plannedBlock.speechSegments {
                try Task.checkCancellation()
                do {
                    for chunk in try await synthesizeWithQualityRetry(subText, voice: voice) {
                        let chunkStartInFile = cursor + blockDuration
                        try await stream.append(chunk)
                        timing.appendSpeech(text: subText, duration: chunk.duration)
                        blockChunkTimings.append((chunk.wordTimings, chunkStartInFile))
                        pronunciationFallbackHits.append(
                            contentsOf: chunk.pronunciationFallbackHits.map {
                                RenderedPronunciationFallbackHit(
                                    blockID: block.id,
                                    audioStartTime: chunkStartInFile,
                                    audioEndTime: chunkStartInFile + chunk.duration,
                                    fallback: $0)
                            })
                        blockDuration += chunk.duration
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isLengthCapError(error) {
                    // A length-cap throw from one sub-chunk must not abort the
                    // whole render unit — skip it and keep going.
                    logger.error(
                        "Skipping over-long sub-chunk in block \(block.id): \(error.localizedDescription)"
                    )
                    continue
                }
            }
            if let assembled = NarrationWordTimingAssembler.assemble(blockChunkTimings) {
                synthesisWordTimingsByBlock[block.id] = assembled
            }
            if !timing.speechRanges.isEmpty {
                speechRangesByBlock[plannedBlock.blockID] = timing.speechRanges
            }

            if plannedBlock.isSpeakable {
                if blockDuration > 0 {
                    anchors.append(
                        AlignmentAnchorRecord(
                            id: "syn-\(audiobookID)-\(block.id)",
                            audiobookID: audiobookID, epubBlockID: block.id,
                            audioTime: cursor, audioEndTime: cursor + blockDuration,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                            source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                            note: nil, createdAt: now, modifiedAt: now))
                    cursor += blockDuration
                    spokenBlockIDs.append(block.id)
                }
                renderedSpeakableBlocks += 1
                logger.notice(
                    "  \(unitLabel): block \(renderedSpeakableBlocks)/\(speakableBlockIDs.count) synthesized"
                )
                let progress =
                    Double(renderedSpeakableBlocks) / Double(max(speakableBlockIDs.count, 1))
                if reportsProgress {
                    state.update(
                        phase: .preparingChapter,
                        progress: progress,
                        statusMessage: "Preparing chapter \(chapterDisplayNumber)…")
                }
                onBlockProgress?(chapterDisplayNumber, progress)
            }
            if let silence = plannedBlock.trailingSilence {
                try await stream.append(.silence(seconds: silence.duration, sampleRate: 24_000))
                cursor += silence.duration
            }
        }

        // Lead-out pad: append trailing silence so the last word has room to ring
        // out and the player can't advance to the next file mid-word. Added AFTER
        // the anchor loop, so the silence is unanchored dead air.
        if includeLeadOutPad, cursor > 0 {
            try await stream.append(
                .silence(seconds: Self.leadOutPadSeconds, sampleRate: 24_000))
        }

        try Task.checkCancellation()
        let duration = try await stream.finalize()
        try Task.checkCancellation()
        if fm.fileExists(atPath: partialURL.path) {
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: partialURL)
            } else {
                try fm.moveItem(at: partialURL, to: fileURL)
            }
        }
        didPublishFinalFile = true

        return RenderedNarrationFile(
            chapterIndex: chapterIndex,
            chapterDisplayNumber: chapterDisplayNumber,
            segmentIndex: segmentIndex,
            fileURL: fileURL,
            duration: duration,
            anchors: anchors,
            spokenBlockIDs: spokenBlockIDs,
            speechRangesByBlock: speechRangesByBlock,
            synthesisWordTimingsByBlock: synthesisWordTimingsByBlock,
            pronunciationFallbackHits: pronunciationFallbackHits)
    }

    private func renderPlan(
        for blocks: [EPubBlockRecord],
        overrides: PronunciationOverrides,
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool
    ) async -> NarrationRenderPlan {
        let preparedBlocks = await prepareBlocksForRenderPlan(
            blocks,
            occurrenceOverrides: occurrenceOverrides,
            fmEnabled: fmEnabled)
        let g2p = KokoroG2P()
        return NarrationRenderPlanner.make(
            blocks: preparedBlocks,
            overrides: overrides,
            phonemeCount: g2p.phonemeCount(for:))
    }

    private func prepareBlocksForRenderPlan(
        _ blocks: [EPubBlockRecord],
        occurrenceOverrides: PronunciationOccurrenceOverrides,
        fmEnabled: Bool
    ) async -> [EPubBlockRecord] {
        var prepared: [EPubBlockRecord] = []
        prepared.reserveCapacity(blocks.count)

        for block in blocks {
            guard block.text?.isEmpty == false, !block.isHidden else {
                prepared.append(block)
                continue
            }

            let normalized = TextNormalizer.normalize(block.text ?? "")
            let refined = fmEnabled ? await FMNormalizer.refine(normalized, cache: fmCache) : normalized
            if refined != normalized {
                do {
                    try await db.write { db in
                        try db.execute(
                            sql: "UPDATE epub_block SET narration_text = ? WHERE id = ?",
                            arguments: [refined, block.id])
                    }
                } catch {
                    logger.error(
                        "Failed to persist FM-refined text for block \(block.id): \(error.localizedDescription)"
                    )
                }
            }

            var preparedBlock = block
            preparedBlock.text = occurrenceOverrides.apply(to: refined, blockID: block.id)
            preparedBlock.narrationText = refined == normalized ? block.narrationText : refined
            prepared.append(preparedBlock)
        }

        return prepared
    }

    private func synthesizeWithQualityRetry(_ text: String, voice: VoiceID) async throws -> [TTSChunk] {
        let first = try await tts.synthesize(text, voice: voice)
        guard case .rejected(let reason) = NarrationChunkQuality.evaluate(first, text: text) else {
            return [first]
        }

        let retryMaxChars = max(20, min(80, text.count / 2))
        let retryTexts = NarrationTextChunker.split(text, maxChars: retryMaxChars)
        guard retryTexts.count > 1 else {
            logger.error(
                "Low-quality narration chunk could not be split for retry: \(String(describing: reason), privacy: .public)"
            )
            return [first]
        }

        logger.warning(
            "Retrying low-quality narration chunk as \(retryTexts.count, privacy: .public) smaller piece(s): \(String(describing: reason), privacy: .public)"
        )
        var retryChunks: [TTSChunk] = []
        retryChunks.reserveCapacity(retryTexts.count)
        for retryText in retryTexts {
            try Task.checkCancellation()
            let retryChunk = try await tts.synthesize(retryText, voice: voice)
            switch NarrationChunkQuality.evaluate(retryChunk, text: retryText) {
            case .acceptable:
                retryChunks.append(retryChunk)
            case .rejected(let retryReason):
                logger.error(
                    "Low-quality narration retry piece rejected; keeping original chunk to avoid dropping source text: \(String(describing: retryReason), privacy: .public)"
                )
                return [first]
            }
        }

        return retryChunks.isEmpty ? [first] : retryChunks
    }

    #if DEBUG && os(iOS)
        /// One-tap on-device smoke test: render the first 3 paragraphs of the
        /// loaded book's chapter 1 with the real Kokoro engine and play them.
        /// Returns an `AVAudioPlayer` so the caller can keep a reference alive.
        @discardableResult
        static func testRenderAndPlayChapterOne(
            databaseWriter: DatabaseWriter,
            audiobookID: String
        ) async throws -> AVAudioPlayer {
            let logger = Logger(category: "NarrationTest")
            var texts: [String] = []
            texts =
                (try? EPubBlockDAO(db: databaseWriter)
                    .blocks(for: audiobookID, chapterIndex: 0)
                    .compactMap { $0.text }
                    .filter { !$0.isEmpty }) ?? []

            if texts.isEmpty {
                logger.info("No EPUB blocks loaded — narrating a sample paragraph instead.")
                texts = [
                    "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.",
                    "Once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it.",
                    "And what is the use of a book, thought Alice, without pictures or conversations?",
                ]
            }
            let snippet = Array(texts.prefix(3))

            logger.info("Preparing narration engine via factory (honors the DEBUG ONNX toggle)…")
            let engine = NarrationEngineFactory.make()
            var chunks: [TTSChunk] = []
            for text in snippet {
                // Chunk before synthesize, mirroring NarrationService.renderChapter:
                // bound every synthesize call under Kokoro's ~510-phoneme context
                // (see NarrationTextChunker for the budget rationale).
                for subText in NarrationTextChunker.split(TextNormalizer.normalize(text)) {
                    chunks.append(
                        try await engine.synthesize(subText, voice: VoiceID("af_heart")))
                }
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("narration-test.m4a")
            try? FileManager.default.removeItem(at: url)
            _ = try await AVFoundationAudioWriter().write(chunks, to: url)

            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            logger.info("Playing \(chunks.count) blocks.")
            return player
        }
    #endif

    /// True for an error that means a single sub-chunk overran the model's input
    /// length cap, so the caller should skip it rather than abort the chapter.
    /// The ONNX engine usually signals this via `NarrationError.lengthCapExceeded`.
    /// Some malformed long fragments surface directly from ONNX Runtime as an
    /// Expand-node shape error; treat that the same way so one bad fragment does
    /// not discard an otherwise rendered chapter.
    private static func isLengthCapError(_ error: Error) -> Bool {
        if case NarrationError.lengthCapExceeded = error { return true }
        let nsError = error as NSError
        let message =
            "\(nsError.domain) \(nsError.localizedDescription) \(String(describing: error))"
        if message.localizedCaseInsensitiveContains("invalid expand shape") {
            return true
        }
        return false
    }
}
