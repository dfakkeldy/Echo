// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

// MARK: - Configuration

/// Input parameters for one narration run.
struct NarrationRunConfig {
    /// Path to an EPUB/PDF source: expanded EPUB directory, .epub archive, or PDF
    /// file. A parent folder may also be provided; runners prefer EPUB over PDF
    /// when both exist.
    var epubURL: URL
    /// Destination for the chaptered .m4b export.
    var outM4BURL: URL
    /// Optional path for the portable alignment sidecar JSON.
    var sidecarURL: URL?
    /// Scratch directory for per-chapter .m4a files and capture markers.
    var workDir: URL
    /// Voice to synthesize with.
    var voice: VoiceID
    /// Book title embedded in the .m4b metadata.
    var title: String
    /// Author embedded in the .m4b metadata.
    var author: String
    /// Cap on how many uncaptured chapters to render in this invocation.
    /// `nil` means render all uncaptured chapters.
    var maxNewChaptersPerRun: Int?
    /// Optional persistent database path. When nil (default), an in-memory
    /// database is used — this keeps FM-refined `narration_text` and QA rows
    /// ephemeral. Set to a .sqlite path to persist across runs for inspection.
    var databaseURL: URL?
    /// Headless batch renders default to deterministic text normalization so the
    /// CLI never waits on optional Foundation Models availability.
    var enableFMNormalization: Bool = false
    /// When `true` (the default), the sidecar's anchors carry per-word timings
    /// read back from the run database's synthesis-time `word_timing` rows.
    /// `false` (the CLI's `--no-word-timings`) writes block anchors only.
    var includeWordTimings: Bool = true
    /// Number of chapters to render concurrently. Each worker owns a private
    /// engine (ONNX session + voice packs — several hundred MB resident), so on
    /// a 16 GB machine 2–4 is the practical ceiling. 1 (default) renders
    /// serially with semantics identical to the pre-parallel runner.
    var jobs: Int = 1
    /// ONNX intra-op threads per engine; `nil` resolves the platform default
    /// for this machine and `jobs` via `NarrationEngineFactory`.
    var intraOpThreads: Int32? = nil
}

// MARK: - Progress

/// Incremental progress events emitted by `HeadlessNarrationRunner.run`.
enum NarrationRunProgress: Sendable {
    /// Importing and parsing the EPUB.
    case importing
    /// One-time engine preparation before the first chapter: model download
    /// fills 0…0.9 and session load 0.9…1. A warm cache jumps straight to 1,
    /// so a fresh environment no longer sits silent through the 163 MB fetch.
    case preparing(fraction: Double)
    /// Synthesizing a chapter (0-based `index` of `of` total chapters).
    case chapter(index: Int, of: Int, fraction: Double)
    /// Concatenating chapter audio and writing the .m4b.
    case exporting
    /// Sidecar written with `anchors` total anchor entries, of which
    /// `anchorsWithWords` carried per-word timings.
    case wroteSidecar(anchors: Int, anchorsWithWords: Int)
}

// MARK: - Result

/// Summary returned after a `HeadlessNarrationRunner.run` call.
struct NarrationRunResult {
    /// Destination URL of the exported .m4b (may not exist yet if `complete == false`).
    var outM4BURL: URL
    /// Total number of chapters in the book.
    var chapters: Int
    /// Total duration of the exported .m4b in seconds (0 if not yet exported).
    var durationSeconds: Double
    /// Number of chapters synthesized during *this* run (0 on a full resume).
    var capturedThisRun: Int
    /// `true` when all chapters are captured and the .m4b has been written.
    var complete: Bool
}

// MARK: - Runner

/// Reusable, testable narration orchestrator extracted from `NarrationHarness`.
///
/// Imports an EPUB, synthesizes uncaptured chapters (batch-safe / resume-safe),
/// exports a chaptered .m4b, and writes a portable alignment sidecar. Each
/// chapter's completion is marked by a `.anchors-ch<N>.json` capture file in
/// `workDir`; a re-run skips already-captured chapters. The .m4b and sidecar
/// are emitted only once every chapter is captured.
///
/// **Crash-partial cleanup:** any `.m4a` in `workDir` whose chapter has no
/// matching capture file is considered a crash partial and is removed before
/// synthesis begins, so it is re-rendered cleanly.
@MainActor final class HeadlessNarrationRunner {

    private enum SourceKind {
        case epubFile(URL)
        case expandedEPUB(URL)
        case pdf(URL)

        var sourceURL: URL {
            switch self {
            case .epubFile(let sourceURL), .expandedEPUB(let sourceURL), .pdf(let sourceURL):
                sourceURL
            }
        }

        /// The zipped `.epub` URL when this source is one, else nil (for OPF cover).
        var epubArchiveURL: URL? {
            if case .epubFile(let url) = self { return url }
            return nil
        }

        /// The expanded EPUB directory when this source is one, else nil.
        var expandedEPUBDir: URL? {
            if case .expandedEPUB(let url) = self { return url }
            return nil
        }
    }

    private enum NarrationRunError: LocalizedError {
        case unsupportedInput(URL)
        case missingSource(URL)
        case noSourceImported(String)
        case noBlocksImported(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedInput(let sourceURL):
                return "Unsupported narration source: \(sourceURL.path)"
            case .missingSource:
                return "No EPUB or PDF source found in the given path."
            case .noSourceImported(let name):
                return "No blocks were imported for \(name)."
            case .noBlocksImported(let name):
                return "No readable text blocks were produced for \(name)."
            }
        }
    }

    // MARK: Capture & sidecar assembly

    /// Per-chapter render capture persisted as `.anchors-ch<N>.json` in the work
    /// dir. All times are chapter-file-relative (each chapter is its own 0-based
    /// audio file); the sidecar assembly converts them to absolute book time.
    /// Internal (not private) so the pure sidecar assembly is unit-testable.
    struct ChapterCapture: Codable, Sendable {
        let duration: TimeInterval
        let anchors: [Entry]
        /// Exact pronunciation evidence returned by `NarrationService` for this
        /// rendered chapter. `nil` identifies a resumable legacy capture whose
        /// audio is valid but whose pronunciation provenance is unavailable.
        let pronunciationEvidence: PronunciationEvidence?

        init(
            duration: TimeInterval,
            anchors: [Entry],
            pronunciationEvidence: PronunciationEvidence? = nil
        ) {
            self.duration = duration
            self.anchors = anchors
            self.pronunciationEvidence = pronunciationEvidence
        }

        struct PronunciationEvidence: Codable, Equatable, Sendable {
            let decisions: [PronunciationAuditDecision]
            let diagnostics: [PronunciationAuditDiagnostic]
        }

        struct Entry: Codable, Sendable {
            let suffix: String
            let time: TimeInterval
            /// Synthesis-time word timings for this block, chapter-file-relative,
            /// in reading order (array position == `word_timing.wordIndex`).
            /// Optional so capture files written by older builds — or with word
            /// export disabled — still decode on a resumed run.
            let words: [Word]?
            struct Word: Codable, Sendable {
                let word: String
                let start: TimeInterval
                let end: TimeInterval
            }

            init(suffix: String, time: TimeInterval, words: [Word]? = nil) {
                self.suffix = suffix
                self.time = time
                self.words = words
            }
        }
    }

    struct IndexedChapterCapture: Sendable {
        let chapterIndex: Int
        let capture: ChapterCapture
    }

    struct PronunciationEvidenceAssembly: Equatable, Sendable {
        let coverage: PronunciationAuditCoverage
        let decisions: [PronunciationAuditDecision]
        let diagnostics: [PronunciationAuditDiagnostic]
        let legacyChapterIndexes: [Int]
        let totalDuration: TimeInterval
    }

    /// Pure resume assembly. Capture filenames provide canonical chapter
    /// identity; sorting them restores reading order independent of parallel
    /// worker completion. The same cumulative duration used by sidecar assembly
    /// shifts both endpoints of every chapter-relative pronunciation range.
    static func assemblePronunciationEvidence(
        indexedCaptures: [IndexedChapterCapture]
    ) -> PronunciationEvidenceAssembly {
        let ordered = indexedCaptures.sorted { lhs, rhs in
            lhs.chapterIndex < rhs.chapterIndex
        }
        var decisions: [PronunciationAuditDecision] = []
        var diagnostics: [PronunciationAuditDiagnostic] = []
        var legacyChapterIndexes: [Int] = []
        var offset: TimeInterval = 0

        for indexedCapture in ordered {
            let chapterIndex = indexedCapture.chapterIndex
            let capture = indexedCapture.capture
            if let evidence = capture.pronunciationEvidence {
                decisions.append(contentsOf: evidence.decisions.map {
                    $0.attachingBookTiming(
                        chapterIndex: chapterIndex,
                        chapterOffset: offset)
                })
                diagnostics.append(contentsOf: evidence.diagnostics.map {
                    $0.attachingChapter(chapterIndex)
                })
            } else {
                legacyChapterIndexes.append(chapterIndex)
            }
            offset += capture.duration
        }

        return PronunciationEvidenceAssembly(
            coverage: legacyChapterIndexes.isEmpty ? .complete : .incompleteLegacyCapture,
            decisions: decisions,
            diagnostics: diagnostics,
            legacyChapterIndexes: legacyChapterIndexes,
            totalDuration: offset)
    }

    /// Pure step-7 assembly: chapter captures (in chapter order) → portable
    /// sidecar anchors, converting per-chapter-relative anchor AND word times to
    /// absolute book time with the same running chapter offset. When
    /// `includeWordTimings` is false the anchors are emitted word-less even if
    /// the captures recorded words (the `--no-word-timings` opt-out).
    static func assembleSidecarAnchors(
        captures: [ChapterCapture],
        includeWordTimings: Bool
    ) -> (anchors: [AlignmentSidecar.Anchor], anchorsWithWords: Int, totalDuration: TimeInterval) {
        var anchors: [AlignmentSidecar.Anchor] = []
        var anchorsWithWords = 0
        var offset: TimeInterval = 0
        for capture in captures {
            for entry in capture.anchors {
                var words: [AlignmentSidecar.Anchor.Word]?
                if includeWordTimings, let captured = entry.words, !captured.isEmpty {
                    words = captured.map {
                        AlignmentSidecar.Anchor.Word(
                            word: $0.word, start: offset + $0.start, end: offset + $0.end)
                    }
                    anchorsWithWords += 1
                }
                anchors.append(
                    AlignmentSidecar.Anchor(
                        blockId: entry.suffix, timestamp: offset + entry.time,
                        confidence: 1.0, words: words))
            }
            offset += capture.duration
        }
        return (anchors, anchorsWithWords, offset)
    }

    /// Builds one chapter's capture entries, attaching each anchor's block's
    /// synthesis word rows when — and only when — the row count matches the
    /// block's whitespace-tokenized text (`WordTokenizer`). A mismatch means the
    /// rendered tokenization diverged from the source text (normalization/G2P),
    /// so `array order == wordIndex` could not hold for consumers; that block's
    /// anchor is captured word-less and read-along falls back to interpolation.
    private static func captureEntries(
        anchors: [AlignmentAnchorRecord],
        wordRows: [WordTimingRecord],
        blocks: [EPubBlockRecord]
    ) -> [ChapterCapture.Entry] {
        let tokenCountByBlockID = Dictionary(
            uniqueKeysWithValues: blocks.map {
                ($0.id, WordTokenizer.words(in: $0.text ?? "").count)
            })
        let rowsByBlockID = Dictionary(grouping: wordRows, by: \.epubBlockID)
        var usedBlockIDs: Set<String> = []
        return anchors.map { anchor in
            var words: [ChapterCapture.Entry.Word]?
            if let rows = rowsByBlockID[anchor.epubBlockID],
                rows.count == tokenCountByBlockID[anchor.epubBlockID],
                !rows.isEmpty,
                usedBlockIDs.insert(anchor.epubBlockID).inserted
            {
                words = rows.map {
                    ChapterCapture.Entry.Word(
                        word: $0.word, start: $0.audioStartTime, end: $0.audioEndTime)
                }
            }
            return ChapterCapture.Entry(
                suffix: AlignmentSidecar.portableSuffix(of: anchor.epubBlockID),
                time: anchor.audioTime,
                words: words)
        }
    }

    /// Chapter-claim cursor shared by parallel render workers. All access is
    /// MainActor-isolated and mutates between suspension points, so two workers
    /// can never claim the same batch position.
    @MainActor private final class BatchCursor {
        /// Next unclaimed position in the batch.
        var next = 0
        /// Chapters fully rendered and captured so far.
        var completed = 0
        /// Per-worker in-flight block fraction (0…1) for aggregate progress.
        var inflight: [Int: Double] = [:]
    }

    /// Collapses engine prepare steps into one 0…1 fraction for
    /// `NarrationRunProgress.preparing`: model download fills 0…0.9, session
    /// load 0.9…1.0. Pure — unit-tested without an engine.
    static func prepareFraction(_ step: NarrationPrepareProgress) -> Double {
        switch step {
        case .downloadingModels(let fraction):
            return 0.9 * min(max(fraction, 0), 1)
        case .compilingModels(let done, let total):
            return 0.9 + 0.1 * (total > 0 ? Double(done) / Double(total) : 0)
        case .ready:
            return 1.0
        }
    }
    private func captureURL(_ idx: Int, in workDir: URL) -> URL {
        workDir.appendingPathComponent(".anchors-ch\(idx).json")
    }

    /// Reads one rendered chapter's track duration + synthesized anchors into a
    /// `ChapterCapture`. Synchronous on purpose: inside the async render worker
    /// closure, `dbWriter.read` would resolve to GRDB's *async* overload (whose
    /// closure must be `@Sendable`); a sync method forces the sync overload.
    private func capturedChapter(
        dbWriter: DatabaseWriter,
        audiobookID: String,
        rendered: NarrationService.RenderedNarrationFile,
        blocks: [EPubBlockRecord],
        includeWordTimings: Bool
    ) throws -> ChapterCapture {
        let blockIDs = blocks.map(\.id)
        let wordRows: [WordTimingRecord] = try dbWriter.read { db in
            let words =
                includeWordTimings
                ? try WordTimingRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(blockIDs.contains(Column("epub_block_id")))
                    .filter(Column("source") == "synthesis")
                    .order(Column("word_index"))
                    .fetchAll(db)
                : []
            return words
        }
        return ChapterCapture(
            duration: rendered.duration,
            anchors: Self.captureEntries(
                anchors: rendered.anchors,
                wordRows: wordRows,
                blocks: blocks),
            pronunciationEvidence: ChapterCapture.PronunciationEvidence(
                decisions: rendered.pronunciationDecisions,
                diagnostics: rendered.pronunciationAuditDiagnostics))
    }

    private func isCaptured(_ idx: Int, in workDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: captureURL(idx, in: workDir).path)
    }

    private func chapterIndex(of url: URL) -> Int? {
        let name = url.lastPathComponent
        guard let r = name.range(of: "-ch") else { return nil }
        return Int(name[r.upperBound...].prefix { $0.isNumber })
    }

    /// Maps each chapter's raw EPUB index to its heading title for export chapter
    /// markers. Pure — unit-tested without rendering audio.
    static func titlesByChapterIndex(_ outline: [NarrationOutlineChapter]) -> [Int: String] {
        Dictionary(
            outline.map { ($0.chapterIndex, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Provenance stamp embedded in the m4b comment (`©cmt`): render date + the
    /// engine/render version, e.g. "Echo narration — 2026-06-23 · ONNX rv7".
    static func narrationVersionStamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return
            "Echo narration — \(formatter.string(from: date)) · ONNX rv\(NarrationFileNaming.renderVersion)"
    }

    /// Resolves cover art for a narration export. The EPUB cover is declared in the
    /// OPF (`<meta name="cover">` / `properties="cover-image"`), not as an inline
    /// content block, so prefer `EpubCoverResolver` for either a zipped archive or
    /// an expanded directory. Falls back to the first front-matter (else any)
    /// inline image block for sources that lack an OPF cover (PDFs) or declare
    /// none. Pure + cross-platform — unit-tested without rendering audio.
    static func coverData(
        epubArchiveURL: URL?,
        expandedEPUBDir: URL?,
        blocks: [EPubBlockRecord],
        fileManager: FileManager = .default
    ) -> Data? {
        if let expandedEPUBDir,
            let data = EpubCoverResolver.coverData(expandedEPUBDir: expandedEPUBDir)
        {
            return data
        }
        if let epubArchiveURL,
            let data = EpubCoverResolver.coverData(epubArchiveURL: epubArchiveURL)
        {
            return data
        }
        let images = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.image.rawValue }
        let front = images.filter(\.isFrontMatter)
        for block in (front.isEmpty ? images : front).sorted(by: {
            $0.sequenceIndex < $1.sequenceIndex
        }) {
            if let path = block.imagePath, fileManager.fileExists(atPath: path),
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            {
                return data
            }
        }
        return nil
    }

    // MARK: run

    /// Execute a narration run per `config`.
    ///
    /// - Parameters:
    ///   - config: All inputs for this run.
    ///   - tts: Engine to use; defaults to `NarrationEngineFactory.make()`.
    ///     When `config.jobs > 1` this single instance is shared by every
    ///     worker — pass `ttsFactory` instead for per-worker engines.
    ///   - ttsFactory: Builds one engine per parallel worker; wins over `tts`.
    ///   - progress: Callback invoked on `@MainActor` as phases complete.
    /// - Returns: A `NarrationRunResult` describing what happened.
    func run(
        _ config: NarrationRunConfig,
        tts: TTSEngine? = nil,
        ttsFactory: (@MainActor () -> TTSEngine)? = nil,
        progress: @escaping @MainActor (NarrationRunProgress) -> Void = { _ in }
    ) async throws -> NarrationRunResult {
        let fm = FileManager.default

        let source = try resolveNarrationSource(at: config.epubURL)
        let sourceURL = source.sourceURL

        // Ensure work directory exists.
        try fm.createDirectory(at: config.workDir, withIntermediateDirectories: true)

        // 1. Import source (EPUB/PDF) → blocks with chapter indices.
        progress(.importing)
        let stem = config.outM4BURL.deletingPathExtension().lastPathComponent
        let audiobookID = "runner-\(stem)-\(sourceURL.lastPathComponent)"
        let db =
            try config.databaseURL.map { try DatabaseService(databaseURL: $0) }
            ?? DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
                arguments: [audiobookID, config.title])
        }
        let blocks = try await importBlocks(
            source: source, into: db, audiobookID: audiobookID)
        guard !blocks.isEmpty else {
            throw NarrationRunError.noBlocksImported(sourceURL.lastPathComponent)
        }

        let byChapter = Dictionary(
            grouping: blocks.filter { $0.chapterIndex != nil },
            by: { $0.chapterIndex! })
        let plannedChapters = NarrationChapterPlanner.plan(from: blocks)
        let plannedByChapterIndex = Dictionary(
            uniqueKeysWithValues: plannedChapters.map { ($0.index, $0) })
        let chapterIndices = byChapter.keys.sorted()

        // 2. Drop crash partials: .m4a files whose chapter has no capture file.
        for url
            in (try? fm.contentsOfDirectory(at: config.workDir, includingPropertiesForKeys: nil))
            ?? []
        where url.pathExtension == "m4a" {
            if let idx = chapterIndex(of: url), !isCaptured(idx, in: config.workDir) {
                try? fm.removeItem(at: url)
            }
        }

        // 3. Determine which chapters to render this batch.
        let pending = chapterIndices.filter { !isCaptured($0, in: config.workDir) }
        let maxNew = config.maxNewChaptersPerRun ?? Int.max
        let batch = Array(pending.prefix(maxNew))

        // 4. Narrate the batch — one worker renders serially with semantics
        //    identical to the historical loop; `config.jobs > 1` runs that many
        //    workers, each owning a private engine + writer. Chapter claims go
        //    through the MainActor `BatchCursor` between suspension points, so
        //    two workers can never take the same chapter; per-chapter capture
        //    markers, m4a files, and track IDs are disjoint by chapter index;
        //    GRDB's single writer queue serializes all database effects, and the
        //    audiobook-scope timeline recalc after each chapter is an idempotent
        //    full recompute, so completion order doesn't matter.
        let totalCount = chapterIndices.count
        let workers = max(1, min(config.jobs, max(batch.count, 1)))
        let resolvedThreads =
            config.intraOpThreads
            ?? NarrationEngineFactory.defaultIntraOpThreads(jobs: workers)
        let makeEngine: @MainActor () -> TTSEngine
        if let ttsFactory {
            makeEngine = ttsFactory
        } else if let tts {
            makeEngine = { tts }
        } else {
            makeEngine = { NarrationEngineFactory.make(intraOpThreads: resolvedThreads) }
        }

        let engines = batch.isEmpty ? [] : (0..<workers).map { _ in makeEngine() }
        if let first = engines.first {
            // Surface the one-time model download/session load that previously
            // happened silently inside the first synthesize call (a fresh
            // environment sat mute through a 163 MB fetch). The other workers'
            // prepare is a fast cache hit on their first synthesize.
            try await first.prepare { step in
                Task { @MainActor in
                    progress(.preparing(fraction: Self.prepareFraction(step)))
                }
            }
        }

        let cursor = BatchCursor()
        // Aggregate batch progress: completed chapters plus every worker's
        // in-flight block fraction. With one worker this reproduces the
        // historical serial values exactly ((batchPos + blockFraction) / count).
        let emitChapterProgress: @MainActor () -> Void = {
            let inflight = cursor.inflight.values.reduce(0, +)
            let fraction =
                (Double(cursor.completed) + inflight) / Double(max(batch.count, 1))
            progress(
                .chapter(
                    index: min(cursor.completed, max(batch.count - 1, 0)),
                    of: batch.count,
                    fraction: fraction))
        }

        // Children capture GRDB's `DatabaseWriter` (Sendable), never the
        // non-Sendable `DatabaseService` wrapper — the region-based isolation
        // checker cannot model the wrapper crossing into N loop-created tasks.
        let dbWriter = db.writer

        let renderChapterAndCapture: @MainActor (Int, NarrationService, Int) async throws -> Void =
            { [self] idx, svc, worker in
                let displayNumber =
                    plannedByChapterIndex[idx]?.displayNumber
                    ?? ((chapterIndices.firstIndex(of: idx) ?? 0) + 1)
                let chapterBlocks = byChapter[idx]!.sorted { $0.sequenceIndex < $1.sequenceIndex }
                let chapterTitle = plannedByChapterIndex[idx]?.title

                let rendered = try await svc.renderChapter(
                    chapterIndex: idx, chapterNumber: displayNumber,
                    blocks: chapterBlocks, voice: config.voice, chapterTitle: chapterTitle
                ) { _, blockFraction in
                    cursor.inflight[worker] = blockFraction
                    emitChapterProgress()
                }

                // Capture anchors + track duration for this chapter.
                let blockIDs = chapterBlocks.map(\.id)
                guard !blockIDs.isEmpty else {
                    // Chapter has no text blocks — SQLite `IN ()` would crash; skip the DB read.
                    let cap = ChapterCapture(
                        duration: rendered.duration,
                        anchors: [],
                        pronunciationEvidence: ChapterCapture.PronunciationEvidence(
                            decisions: rendered.pronunciationDecisions,
                            diagnostics: rendered.pronunciationAuditDiagnostics))
                    try JSONEncoder().encode(cap).write(
                        to: captureURL(idx, in: config.workDir),
                        options: .atomic)
                    return
                }
                let cap = try capturedChapter(
                    dbWriter: dbWriter, audiobookID: audiobookID,
                    rendered: rendered,
                    blocks: chapterBlocks,
                    includeWordTimings: config.includeWordTimings)
                try JSONEncoder().encode(cap).write(
                    to: captureURL(idx, in: config.workDir),
                    options: .atomic)
            }

        // Unstructured Tasks (not a TaskGroup) on purpose: `Task {}` inherits
        // this method's MainActor isolation, so captures need no Sendable
        // proof — the region-based isolation checker rejects the equivalent
        // `group.addTask` pattern outright ("pattern … does not understand").
        // Error semantics match the group: the first failure stops further
        // chapter claims (in-flight chapters finish and persist their capture
        // markers, keeping the work dir resume-safe) and is rethrown.
        var workerTasks: [Task<Void, Error>] = []
        for worker in 0..<(batch.isEmpty ? 0 : workers) {
            let engine = engines[worker]
            workerTasks.append(
                Task {
                    let svc = NarrationService(
                        db: dbWriter, audiobookID: audiobookID, tts: engine,
                        audioWriter: AVFoundationAudioWriter(),
                        cacheDirectory: config.workDir, state: NarrationState(),
                        pronunciationOverrides: {
                            PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
                        },
                        pronunciationOccurrenceOverrides: {
                            PronunciationOverrideStore.shared.occurrenceOverrides(
                                forBookID: audiobookID)
                        },
                        fmEnabled: { config.enableFMNormalization })
                    while cursor.next < batch.count {
                        let pos = cursor.next
                        cursor.next += 1
                        cursor.inflight[worker] = 0
                        emitChapterProgress()
                        do {
                            try await renderChapterAndCapture(batch[pos], svc, worker)
                        } catch {
                            cursor.inflight[worker] = nil
                            throw error
                        }
                        // Clear in-flight BEFORE counting the chapter complete,
                        // or the aggregate transiently double-counts it.
                        cursor.inflight[worker] = nil
                        cursor.completed += 1
                        emitChapterProgress()
                    }
                })
        }
        var firstWorkerError: Error?
        for task in workerTasks {
            do {
                try await task.value
            } catch {
                if firstWorkerError == nil { firstWorkerError = error }
                // Stop idle workers from claiming further chapters.
                cursor.next = batch.count
            }
        }
        if let firstWorkerError { throw firstWorkerError }

        // 5. Check if all chapters are now captured.
        let stillPending = chapterIndices.filter { !isCaptured($0, in: config.workDir) }
        guard stillPending.isEmpty else {
            // Partial batch complete; caller should re-run.
            return NarrationRunResult(
                outM4BURL: config.outM4BURL,
                chapters: totalCount,
                durationSeconds: 0,
                capturedThisRun: batch.count,
                complete: false)
        }

        // 6. Export the chaptered .m4b.
        progress(.exporting)
        try fm.createDirectory(
            at: config.outM4BURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let m4aFiles =
            ((try? fm.contentsOfDirectory(at: config.workDir, includingPropertiesForKeys: nil))
            ?? [])
            .filter { $0.pathExtension == "m4a" }
        let ordered = m4aFiles.compactMap { url -> (Int, URL)? in
            chapterIndex(of: url).map { ($0, url) }
        }.sorted { $0.0 < $1.0 }

        // Title each chapter from its EPUB heading (keyed by chapter index, never
        // file position) so the exported .m4b carries real chapter names — not
        // "Chapter N". Falls back to "Chapter <index+1>" when a chapter has no heading.
        let titles = Self.titlesByChapterIndex(
            NarrationOutlineBuilder.build(allBlocks: blocks, isRendered: { _ in true }))
        let items = ordered.map { chapterIndex, url in
            ExportItem(
                title: titles[chapterIndex] ?? "Chapter \(chapterIndex + 1)",
                url: url, timeRange: nil)
        }

        // Cover art: prefer the OPF-declared cover for ANY EPUB source — zipped
        // (.epubFile) or expanded — since the cover lives in the OPF, not as an
        // inline content image. PDFs and cover-less EPUBs fall back to the first
        // front-matter (else any) inline image block.
        let coverData = Self.coverData(
            epubArchiveURL: source.epubArchiveURL,
            expandedEPUBDir: source.expandedEPUBDir,
            blocks: blocks)

        try await AudioExportService().exportM4B(
            items: items, outputURL: config.outM4BURL,
            metadata: ExportMetadata(
                title: config.title, author: config.author, coverArt: coverData,
                comment: Self.narrationVersionStamp()))

        // 7. Assemble the portable alignment sidecar (per-chapter relative → absolute,
        // for anchor timestamps AND their word times alike).
        let indexedCaptures = try chapterIndices.map { idx in
            IndexedChapterCapture(
                chapterIndex: idx,
                capture: try JSONDecoder().decode(
                    ChapterCapture.self,
                    from: Data(contentsOf: captureURL(idx, in: config.workDir))))
        }
        let captures = indexedCaptures.map(\.capture)
        let pronunciationEvidence = Self.assemblePronunciationEvidence(
            indexedCaptures: indexedCaptures)
        var totalDuration = pronunciationEvidence.totalDuration
        if let sidecarURL = config.sidecarURL {
            let assembled = Self.assembleSidecarAnchors(
                captures: captures, includeWordTimings: config.includeWordTimings)
            totalDuration = assembled.totalDuration
            try fm.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try AlignmentSidecar.encode(assembled.anchors).write(to: sidecarURL, options: .atomic)
            progress(
                .wroteSidecar(
                    anchors: assembled.anchors.count,
                    anchorsWithWords: assembled.anchorsWithWords))
        }

        return NarrationRunResult(
            outM4BURL: config.outM4BURL,
            chapters: totalCount,
            durationSeconds: totalDuration,
            capturedThisRun: batch.count,
            complete: true)
    }

    private func importBlocks(
        source: SourceKind,
        into db: DatabaseService,
        audiobookID: String
    ) async throws -> [EPubBlockRecord] {
        let importer = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))

        switch source {
        case .expandedEPUB(let epubURL):
            return try await importer.import(
                audiobookID: audiobookID,
                epubURL: epubURL,
                chapters: [],
                bookDuration: nil)
        case .epubFile(let epubURL):
            // Headless narration imports with no book duration, so
            // DocumentImportFinalizer skips the community-CloudKit anchor query
            // (which would stall/fault with no iCloud entitlement).
            let didImport = await EPUBAutoImportScanner.importEPUBFile(
                epubURL: epubURL,
                audiobookID: audiobookID,
                databaseService: db,
                chapters: [],
                duration: nil,
                force: true)
            guard didImport else {
                throw NarrationRunError.noSourceImported(epubURL.lastPathComponent)
            }
            do {
                return try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
            } catch {
                return []
            }
        case .pdf(let pdfURL):
            let imported = await PDFAutoImportScanner.importPDFFile(
                pdfURL: pdfURL,
                audiobookID: audiobookID,
                databaseService: db,
                chapters: [],
                duration: nil,
                force: true)
            guard imported else {
                throw NarrationRunError.noSourceImported(pdfURL.lastPathComponent)
            }
            do {
                return try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
            } catch {
                return []
            }
        }
    }

    private func resolveNarrationSource(at sourceURL: URL) throws -> SourceKind {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            if isExpandedEPUB(sourceURL) {
                return .expandedEPUB(sourceURL)
            }

            let entries = try fm.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles)
            if let epubURL =
                entries
                .filter({ $0.pathExtension.lowercased() == "epub" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first
            {
                return .epubFile(epubURL)
            }

            if let pdfURL =
                entries
                .filter({ $0.pathExtension.lowercased() == "pdf" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .first
            {
                return .pdf(pdfURL)
            }

            throw NarrationRunError.missingSource(sourceURL)
        }

        let ext = sourceURL.pathExtension.lowercased()
        switch ext {
        case "epub":
            return .epubFile(sourceURL)
        case "pdf":
            return .pdf(sourceURL)
        default:
            throw NarrationRunError.unsupportedInput(sourceURL)
        }
    }

    private func isExpandedEPUB(_ sourceURL: URL) -> Bool {
        let containerPath = sourceURL.appendingPathComponent("META-INF/container.xml").path
        let mimetypePath = sourceURL.appendingPathComponent("mimetype").path
        return FileManager.default.fileExists(atPath: containerPath)
            && FileManager.default.fileExists(atPath: mimetypePath)
    }
}
