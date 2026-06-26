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
}

// MARK: - Progress

/// Incremental progress events emitted by `HeadlessNarrationRunner.run`.
enum NarrationRunProgress: Sendable {
    /// Importing and parsing the EPUB.
    case importing
    /// Synthesizing a chapter (0-based `index` of `of` total chapters).
    case chapter(index: Int, of: Int, fraction: Double)
    /// Concatenating chapter audio and writing the .m4b.
    case exporting
    /// Sidecar written with `anchors` total anchor entries.
    case wroteSidecar(anchors: Int)
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

    // MARK: Private helpers

    private struct ChapterCapture: Codable {
        let duration: TimeInterval
        let anchors: [Entry]
        struct Entry: Codable {
            let suffix: String
            let time: TimeInterval
        }
    }

    private func captureURL(_ idx: Int, in workDir: URL) -> URL {
        workDir.appendingPathComponent(".anchors-ch\(idx).json")
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

    // MARK: run

    /// Execute a narration run per `config`.
    ///
    /// - Parameters:
    ///   - config: All inputs for this run.
    ///   - tts: Engine to use; defaults to `NarrationEngineFactory.make()`.
    ///   - progress: Callback invoked on `@MainActor` as phases complete.
    /// - Returns: A `NarrationRunResult` describing what happened.
    func run(
        _ config: NarrationRunConfig,
        tts: TTSEngine? = nil,
        progress: @escaping @MainActor (NarrationRunProgress) -> Void = { _ in }
    ) async throws -> NarrationRunResult {
        let fm = FileManager.default
        let engine = tts ?? NarrationEngineFactory.make()

        let source = try resolveNarrationSource(at: config.epubURL)
        let sourceURL = source.sourceURL

        // Ensure work directory exists.
        try fm.createDirectory(at: config.workDir, withIntermediateDirectories: true)

        // 1. Import source (EPUB/PDF) → blocks with chapter indices.
        progress(.importing)
        let stem = config.outM4BURL.deletingPathExtension().lastPathComponent
        let audiobookID = "runner-\(stem)-\(sourceURL.lastPathComponent)"
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
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

        // 4. Narrate each chapter in the batch.
        let writer = AVFoundationAudioWriter()
        let svc = NarrationService(
            db: db.writer, audiobookID: audiobookID, tts: engine,
            audioWriter: writer, cacheDirectory: config.workDir, state: NarrationState(),
            pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })

        let totalCount = chapterIndices.count
        for (batchPos, idx) in batch.enumerated() {
            let displayNumber =
                plannedByChapterIndex[idx]?.displayNumber
                ?? ((chapterIndices.firstIndex(of: idx) ?? 0) + 1)
            let chapterBlocks = byChapter[idx]!.sorted { $0.sequenceIndex < $1.sequenceIndex }
            let chapterTitle = plannedByChapterIndex[idx]?.title

            progress(
                .chapter(
                    index: batchPos, of: batch.count,
                    fraction: Double(batchPos) / Double(max(batch.count, 1))))

            try await svc.renderChapter(
                chapterIndex: idx, chapterNumber: displayNumber,
                blocks: chapterBlocks, voice: config.voice, chapterTitle: chapterTitle
            ) { _, blockFraction in
                let batchFraction =
                    (Double(batchPos) + blockFraction)
                    / Double(max(batch.count, 1))
                progress(
                    .chapter(
                        index: batchPos,
                        of: batch.count,
                        fraction: batchFraction))
            }

            // Capture anchors + track duration for this chapter.
            let blockIDs = chapterBlocks.map(\.id)
            guard !blockIDs.isEmpty else {
                // Chapter has no text blocks — SQLite `IN ()` would crash; skip the DB read.
                let cap = ChapterCapture(duration: 0, anchors: [])
                try JSONEncoder().encode(cap).write(to: captureURL(idx, in: config.workDir))
                continue
            }
            let trackID = "syn-\(audiobookID)-ch\(idx)"
            let (duration, entries): (TimeInterval, [ChapterCapture.Entry]) = try db.read { db in
                let dur =
                    try TrackRecord.filter(Column("id") == trackID).fetchOne(db)?.duration ?? 0
                let anchors =
                    try AlignmentAnchorRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(Column("source") == AlignmentAnchorRecord.Source.synthesized.rawValue)
                    .filter(blockIDs.contains(Column("epub_block_id")))
                    .order(Column("audio_time"))
                    .fetchAll(db)
                return (
                    dur,
                    anchors.map {
                        ChapterCapture.Entry(
                            suffix: AlignmentSidecar.portableSuffix(of: $0.epubBlockID),
                            time: $0.audioTime)
                    }
                )
            }
            let cap = ChapterCapture(duration: duration, anchors: entries)
            try JSONEncoder().encode(cap).write(to: captureURL(idx, in: config.workDir))
        }

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

        // Cover art: prefer the OPF-declared cover (where EPUB covers actually live);
        // fall back to a front-matter inline image block.
        let coverData: Data? = {
            switch source {
            case .expandedEPUB(let epubURL):
                return EpubCoverResolver.coverData(expandedEPUBDir: epubURL)
                    ?? {
                        let images = blocks.filter {
                            $0.blockKind == EPubBlockRecord.Kind.image.rawValue
                        }
                        let front = images.filter(\.isFrontMatter)
                        for b in (front.isEmpty ? images : front).sorted(by: {
                            $0.sequenceIndex < $1.sequenceIndex
                        }) {
                            if let p = b.imagePath, fm.fileExists(atPath: p),
                                let d = try? Data(contentsOf: URL(fileURLWithPath: p))
                            {
                                return d
                            }
                        }
                        return nil
                    }()
            case .epubFile, .pdf:
                let images = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.image.rawValue }
                let front = images.filter(\.isFrontMatter)
                for b in (front.isEmpty ? images : front).sorted(by: {
                    $0.sequenceIndex < $1.sequenceIndex
                }) {
                    if let p = b.imagePath, fm.fileExists(atPath: p),
                        let d = try? Data(contentsOf: URL(fileURLWithPath: p))
                    {
                        return d
                    }
                }
                return nil
            }
        }()

        try await AudioExportService().exportM4B(
            items: items, outputURL: config.outM4BURL,
            metadata: ExportMetadata(
                title: config.title, author: config.author, coverArt: coverData,
                comment: Self.narrationVersionStamp()))

        // 7. Assemble the portable alignment sidecar (per-chapter relative → absolute).
        var totalDuration: TimeInterval = 0
        if let sidecarURL = config.sidecarURL {
            var sidecar: [AlignmentSidecar.Anchor] = []
            var offset: TimeInterval = 0
            for idx in chapterIndices {
                let cap = try JSONDecoder().decode(
                    ChapterCapture.self,
                    from: Data(contentsOf: captureURL(idx, in: config.workDir)))
                for a in cap.anchors {
                    sidecar.append(
                        AlignmentSidecar.Anchor(
                            blockId: a.suffix, timestamp: offset + a.time, confidence: 1.0))
                }
                offset += cap.duration
            }
            totalDuration = offset
            try fm.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)
            progress(.wroteSidecar(anchors: sidecar.count))
        } else {
            // Compute duration without sidecar.
            for idx in chapterIndices {
                let cap = try JSONDecoder().decode(
                    ChapterCapture.self,
                    from: Data(contentsOf: captureURL(idx, in: config.workDir)))
                totalDuration += cap.duration
            }
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
