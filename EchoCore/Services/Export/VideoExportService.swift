// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import os.log

/// The immutable, product-valid H.264 settings for one export. Holds only the
/// two `Int` dimensions, so it is trivially `Sendable`; its `[String: Any]`
/// `outputSettings` dictionary is materialized on demand and only ever inside
/// the actor (preflight) or on the actor's `writeMovie` path, so the non-Sendable
/// dictionary never crosses the `@Sendable` capability boundary below.
nonisolated struct H264VideoSettings: Equatable, Sendable {
    let width: Int
    let height: Int

    var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    }
}

/// A pluggable "can the live encoder accept these settings?" seam. `.live`
/// asks AVFoundation via `AVAssetWriter.canApply(outputSettings:forMediaType:)`;
/// tests inject a deterministic closure. Only the `Sendable` `H264VideoSettings`
/// value crosses the closure — the `[String: Any]` is built inside it.
nonisolated struct H264VideoSettingsCapability: Sendable {
    let supports: @Sendable (H264VideoSettings) throws -> Bool
    static let live: Self = .init { settings in
        let url = FileManager.default.temporaryDirectory
            .appending(path: "echo-video-preflight-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        return writer.canApply(
            outputSettings: settings.outputSettings,
            forMediaType: .video
        )
    }
}

/// Whole-book slideshow video exporter: H.264/AAC MP4 with sparse frames from
/// `SlideshowExportPlanner`, plus `.srt` and `.chapters.txt` sidecars.
actor VideoExportService {
    /// Semantic preflight failures plus the fallback for writer/reader states
    /// that provide no underlying AVFoundation error. Because Swift throws are
    /// untyped, callers must also handle underlying source, disk, and media errors.
    enum ExportError: Error {
        case noAudio
        case noAlignment
        case writerFailed
        /// The requested (product-valid) dimensions produce H.264 settings the
        /// live encoder rejected. Raised by the entry preflight, before any
        /// source/database/output work, so nothing on disk is created.
        case unsupportedVideoSettings(width: Int, height: Int)
    }

    struct Output: Sendable {
        let videoURL: URL
        let srtURL: URL
        let chaptersURL: URL
    }

    private struct ResolvedSourceItem: Sendable {
        let title: String
        let url: URL
        let timeRange: CMTimeRange?
        let emitsChapterMarker: Bool

        init(_ item: ExportItem) {
            title = item.title
            url = item.url
            timeRange = item.timeRange
            emitsChapterMarker = item.emitsChapterMarker
        }

        var exportItem: ExportItem {
            ExportItem(
                title: title,
                url: url,
                timeRange: timeRange,
                emitsChapterMarker: emitsChapterMarker)
        }
    }

    /// AVFoundation documents feeding distinct writer inputs concurrently. These
    /// boxes are the only unchecked boundary: each input and the renderer/reader
    /// that feeds it is owned by exactly one child task until the group joins.
    /// TODO(export-avfoundation-receivers): Remove all three unchecked bridges when
    /// receiver-based writer APIs can replace them while preserving iOS 18/macOS 15.
    private nonisolated final class VideoPumpBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let renderer: SlideshowFrameRenderer

        init(
            input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            renderer: SlideshowFrameRenderer
        ) {
            self.input = input
            self.adaptor = adaptor
            self.renderer = renderer
        }
    }

    private nonisolated final class AudioPumpBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let reader: AVAssetReader

        init(input: AVAssetWriterInput, output: AVAssetReaderOutput, reader: AVAssetReader) {
            self.input = input
            self.output = output
            self.reader = reader
        }
    }

    private nonisolated final class WriterStatusBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }
    }

    private let logger = Logger(category: "VideoExport")

    /// The H.264 capability preflight seam. Defaults to the live AVFoundation
    /// query; tests inject a deterministic closure.
    private let h264Capability: H264VideoSettingsCapability

    init(h264Capability: H264VideoSettingsCapability = .live) {
        self.h264Capability = h264Capability
    }

    func exportVideo(
        audiobookID: String,
        bookTitle: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL,
        outputDirectory: URL,
        mode: SlideshowExportMode = .karaoke,
        syncPoint: VisualListeningSyncPoint = .midpoint,
        dimensions: SlideshowVideoDimensions = .landscape,
        range: Range<TimeInterval>? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        try Task.checkCancellation()

        // Live H.264 preflight FIRST — before any source resolution, database
        // read, audio assembly, or output-directory/named-output creation — so a
        // rejected configuration fails cleanly with nothing written to disk. The
        // same value is handed to `writeMovie`, so preflight and encode cannot
        // diverge.
        let videoSettings = H264VideoSettings(
            width: dimensions.width, height: dimensions.height)
        guard try h264Capability.supports(videoSettings) else {
            throw ExportError.unsupportedVideoSettings(
                width: dimensions.width, height: dimensions.height)
        }

        let resolved = try await Self.resolveSourceItems(
            audiobookID: audiobookID,
            databaseWriter: databaseWriter,
            cacheDirectory: cacheDirectory)
        let sourceItems = resolved.map(\.exportItem)
        guard !sourceItems.isEmpty else { throw ExportError.noAudio }

        let timeline = try TimelineRowLoader.rows(
            audiobookID: audiobookID, db: databaseWriter)
        guard !timeline.isEmpty else { throw ExportError.noAlignment }
        let blocks = try EPubBlockDAO(db: databaseWriter).visibleBlocks(for: audiobookID)
        let words: [ReaderActiveBlockResolver.WordRow] =
            (try? WordTimingDAO(db: databaseWriter).words(forAudiobook: audiobookID))?
            .map {
                (
                    start: $0.audioStartTime,
                    end: $0.audioEndTime,
                    blockID: $0.epubBlockID,
                    wordIndex: $0.wordIndex
                )
            } ?? []

        // Imported originals can be security-scoped. Keep every distinct source
        // open until AVAssetReader has finished consuming the composition.
        let sourceURLs = Set(sourceItems.map(\.url))
        var scopedURLs: [URL] = []
        for url in sourceURLs where url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
        defer {
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let composition = AVMutableComposition()
        guard
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ExportError.writerFailed
        }

        // Only items that actually contribute an audio track feed the planner.
        // Keeping these arrays parallel avoids shifting durations/scopes when a
        // malformed or empty source asset has no audio track.
        var insertedItems: [ExportItem] = []
        var measuredDurations: [TimeInterval] = []
        var chapterMarks: [SlideshowChapterMark] = []
        var position = CMTime.zero
        for item in sourceItems {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: item.url)
            let fullDuration = try await asset.load(.duration)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            let itemRange = item.timeRange ?? CMTimeRange(start: .zero, duration: fullDuration)
            guard itemRange.duration.isNumeric, itemRange.duration > .zero else { continue }

            try audioTrack.insertTimeRange(itemRange, of: sourceTrack, at: position)
            if item.emitsChapterMarker {
                chapterMarks.append(
                    SlideshowChapterMark(startTime: position.seconds, title: item.title))
            }
            insertedItems.append(item)
            measuredDurations.append(itemRange.duration.seconds)
            position = CMTimeAdd(position, itemRange.duration)
        }
        guard !insertedItems.isEmpty, position.isNumeric, position > .zero else {
            throw ExportError.noAudio
        }

        let effectiveRange = Self.normalizedRange(range, totalDuration: position.seconds)
        if let effectiveRange {
            guard !effectiveRange.isEmpty else { throw ExportError.noAlignment }
            let rangeEnd = CMTime(seconds: effectiveRange.upperBound, preferredTimescale: 600)
            if rangeEnd < position {
                composition.removeTimeRange(
                    CMTimeRange(
                        start: rangeEnd,
                        duration: CMTimeSubtract(position, rangeEnd)))
            }
            let rangeStart = CMTime(seconds: effectiveRange.lowerBound, preferredTimescale: 600)
            if rangeStart > .zero {
                composition.removeTimeRange(
                    CMTimeRange(start: .zero, duration: rangeStart))
            }
            chapterMarks = chapterMarks.compactMap { mark in
                let shifted = mark.startTime - effectiveRange.lowerBound
                guard shifted >= 0, shifted < effectiveRange.upperBound - effectiveRange.lowerBound
                else { return nil }
                return SlideshowChapterMark(startTime: shifted, title: mark.title)
            }
        }

        let contexts = Self.trackContexts(
            items: insertedItems, measuredDurations: measuredDurations)
        let compactedAlignment = Self.compactedAlignment(
            timeline: timeline,
            words: words,
            items: insertedItems,
            measuredDurations: measuredDurations)
        guard !compactedAlignment.timeline.isEmpty else {
            throw ExportError.noAlignment
        }
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks,
            timeline: compactedAlignment.timeline,
            words: compactedAlignment.words,
            tracks: contexts,
            mode: mode,
            syncPoint: syncPoint,
            range: effectiveRange)
        guard !plan.frames.isEmpty, plan.totalDuration > 0 else {
            throw ExportError.noAlignment
        }

        let metadata = await ExportMetadataResolver.resolve(
            audiobookID: audiobookID,
            fallbackTitle: bookTitle,
            firstSourceURL: insertedItems.first?.url,
            databaseWriter: databaseWriter)
        let coverArt = metadata.coverArt.flatMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let renderer = SlideshowFrameRenderer(
            dimensions: dimensions,
            coverArt: coverArt)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let safeTitle = SafeFileName.sanitizeForFilename(bookTitle)
        let output = Output(
            videoURL: outputDirectory.appendingPathComponent("\(safeTitle).mp4"),
            srtURL: outputDirectory.appendingPathComponent("\(safeTitle).srt"),
            chaptersURL: outputDirectory.appendingPathComponent("\(safeTitle).chapters.txt"))

        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let rawVideoURL = stagingDirectory.appendingPathComponent("raw.mp4")
        let stagedVideoURL = stagingDirectory.appendingPathComponent("final.mp4")
        let stagedSRTURL = stagingDirectory.appendingPathComponent("final.srt")
        let stagedChaptersURL = stagingDirectory.appendingPathComponent("final.chapters.txt")

        try await writeMovie(
            plan: plan,
            renderer: renderer,
            audioComposition: composition,
            to: rawVideoURL,
            videoSettings: videoSettings,
            onProgress: onProgress)
        try Task.checkCancellation()

        var chapterAtomsWereStamped = false
        if !chapterMarks.isEmpty {
            let atoms = chapterMarks.map {
                ChapterAtom(startTime: $0.startTime, title: $0.title)
            }
            do {
                try await ChapterMarkerWriter().writeChapters(
                    atoms,
                    to: rawVideoURL,
                    outputURL: stagedVideoURL,
                    metadata: metadata)
                let stampedAsset = AVURLAsset(url: stagedVideoURL)
                let locales = try await stampedAsset.load(.availableChapterLocales)
                let preferredLanguages =
                    locales.isEmpty
                    ? ["en"] : locales.map(\.identifier)
                let groups = try await stampedAsset.loadChapterMetadataGroups(
                    bestMatchingPreferredLanguages: preferredLanguages)
                chapterAtomsWereStamped = groups.count == chapterMarks.count
            } catch {
                logger.info(
                    "MP4 chapter atoms unavailable; preserving the video and sidecar chapters: \(error.localizedDescription)"
                )
            }
        }
        if !chapterAtomsWereStamped {
            try? fileManager.removeItem(at: stagedVideoURL)
            try fileManager.copyItem(at: rawVideoURL, to: stagedVideoURL)
        }

        try SRTFormatter.srtDocument(cues: plan.srtCues)
            .write(to: stagedSRTURL, atomically: true, encoding: .utf8)
        try SRTFormatter.chaptersDocument(marks: chapterMarks)
            .write(to: stagedChaptersURL, atomically: true, encoding: .utf8)
        try Task.checkCancellation()

        do {
            for url in [output.videoURL, output.srtURL, output.chaptersURL] {
                try? fileManager.removeItem(at: url)
            }
            try fileManager.copyItem(at: stagedVideoURL, to: output.videoURL)
            try fileManager.copyItem(at: stagedSRTURL, to: output.srtURL)
            try fileManager.copyItem(at: stagedChaptersURL, to: output.chaptersURL)
            try Task.checkCancellation()
        } catch {
            // Never leave a named partial bundle that can be mistaken for a
            // successful export or paired with stale sidecars.
            for url in [output.videoURL, output.srtURL, output.chaptersURL] {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }

        onProgress(1)
        return output
    }

    // MARK: - Track contexts

    struct AlignmentRows {
        let timeline: [ReaderActiveBlockResolver.TimelineRow]
        let words: [ReaderActiveBlockResolver.WordRow]
    }

    /// A single imported M4B keeps alignment on its original source clock even
    /// when disabled chapters make its enabled `ExportItem` slices sparse. Audio
    /// assembly concatenates those slices, so project the matching alignment onto
    /// that same compacted axis before planning frames and SRT cues.
    static func compactedAlignment(
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        items: [ExportItem],
        measuredDurations: [TimeInterval]
    ) -> AlignmentRows {
        guard !items.isEmpty,
            items.count == measuredDurations.count,
            Set(items.map(\.url)).count == 1,
            items.allSatisfy({ $0.timeRange != nil })
        else {
            return AlignmentRows(timeline: timeline, words: words)
        }

        struct Slice {
            let sourceStart: TimeInterval
            var sourceEnd: TimeInterval
            let destinationStart: TimeInterval

            var destinationEnd: TimeInterval {
                destinationStart + sourceEnd - sourceStart
            }
        }

        var slices: [Slice] = []
        var destinationStart: TimeInterval = 0
        for (item, duration) in zip(items, measuredDurations) {
            guard let range = item.timeRange,
                range.start.isNumeric,
                duration.isFinite,
                duration > 0
            else {
                return AlignmentRows(timeline: timeline, words: words)
            }
            let sourceStart = range.start.seconds
            let sourceEnd = sourceStart + duration
            guard sourceStart.isFinite, sourceEnd.isFinite else {
                return AlignmentRows(timeline: timeline, words: words)
            }

            if var previous = slices.last,
                abs(previous.sourceEnd - sourceStart) < 0.000_001
            {
                previous.sourceEnd = sourceEnd
                slices[slices.count - 1] = previous
            } else {
                slices.append(
                    Slice(
                        sourceStart: sourceStart,
                        sourceEnd: sourceEnd,
                        destinationStart: destinationStart))
            }
            destinationStart += duration
        }

        var projectedTimeline: [ReaderActiveBlockResolver.TimelineRow] = []
        var sliceIndicesByBlockID: [String: [Int]] = [:]
        for (sliceIndex, slice) in slices.enumerated() {
            for row in timeline {
                let start = max(row.start, slice.sourceStart)
                let end = min(row.end, slice.sourceEnd)
                guard end > start else { continue }
                projectedTimeline.append(
                    (
                        start: slice.destinationStart + start - slice.sourceStart,
                        end: slice.destinationStart + end - slice.sourceStart,
                        blockID: row.blockID,
                        chapterIndex: row.chapterIndex,
                        segmentKey: row.segmentKey
                    ))
                if sliceIndicesByBlockID[row.blockID]?.last != sliceIndex {
                    sliceIndicesByBlockID[row.blockID, default: []].append(sliceIndex)
                }
            }
        }

        // Keep one projected row for every timed word in a retained block. Words
        // outside a partial slice collapse to its nearest boundary (zero duration)
        // so resolver array positions remain display-token ordinals while only
        // selected audio can become active.
        var projectedWords: [ReaderActiveBlockResolver.WordRow] = []
        for word in words {
            guard let sliceIndices = sliceIndicesByBlockID[word.blockID],
                !sliceIndices.isEmpty
            else { continue }

            if let sliceIndex = sliceIndices.first(where: { index in
                word.end > slices[index].sourceStart && word.start < slices[index].sourceEnd
            }) {
                let slice = slices[sliceIndex]
                let start = max(word.start, slice.sourceStart)
                let end = min(word.end, slice.sourceEnd)
                projectedWords.append(
                    (
                        start: slice.destinationStart + start - slice.sourceStart,
                        end: slice.destinationStart + end - slice.sourceStart,
                        blockID: word.blockID,
                        wordIndex: word.wordIndex
                    ))
                continue
            }

            var nearestSlice = slices[sliceIndices[0]]
            var nearestDistance = TimeInterval.greatestFiniteMagnitude
            for sliceIndex in sliceIndices {
                let slice = slices[sliceIndex]
                let distance =
                    word.end <= slice.sourceStart
                    ? slice.sourceStart - word.end : word.start - slice.sourceEnd
                if distance < nearestDistance {
                    nearestSlice = slice
                    nearestDistance = distance
                }
            }
            let boundary =
                word.end <= nearestSlice.sourceStart
                ? nearestSlice.destinationStart : nearestSlice.destinationEnd
            projectedWords.append(
                (
                    start: boundary,
                    end: boundary,
                    blockID: word.blockID,
                    wordIndex: word.wordIndex
                ))
        }
        projectedWords.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.blockID != $1.blockID { return $0.blockID < $1.blockID }
            return $0.wordIndex < $1.wordIndex
        }
        return AlignmentRows(timeline: projectedTimeline, words: projectedWords)
    }

    @MainActor
    private static func resolveSourceItems(
        audiobookID: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL
    ) async throws -> [ResolvedSourceItem] {
        let source = ExportSourceResolver.resolve(
            audiobookID: audiobookID,
            databaseWriter: databaseWriter,
            cacheDirectory: cacheDirectory)
        return try await sourceItems(from: source).map(ResolvedSourceItem.init)
    }

    /// Maps only the resolver's explicit "no local source" condition. Cancellation
    /// and all other underlying errors pass through unchanged.
    @MainActor
    static func sourceItems(from source: ExportSource) async throws -> [ExportItem] {
        do {
            return try await source.items()
        } catch ImportedBookSource.SourceError.sourceUnavailable {
            throw ExportError.noAudio
        }
    }

    /// Groups consecutive items by source URL, then applies the exact chapter
    /// and segment scoping used by the live player.
    static func trackContexts(
        items: [ExportItem], measuredDurations: [TimeInterval]
    ) -> [SlideshowTrackContext] {
        struct Group {
            var title: String
            var url: URL
            var duration: TimeInterval
        }

        var groups: [Group] = []
        for (index, item) in items.enumerated() {
            let duration =
                measuredDurations.indices.contains(index)
                ? measuredDurations[index] : 0
            if var last = groups.last, last.url == item.url {
                last.duration += duration
                groups[groups.count - 1] = last
            } else {
                groups.append(Group(title: item.title, url: item.url, duration: duration))
            }
        }

        let isMultiM4B =
            groups.count >= 2
            && groups.allSatisfy { $0.url.pathExtension.lowercased() == "m4b" }
        return groups.enumerated().map { index, group in
            let fileName = group.url.lastPathComponent
            let location = NarrationFileNaming.segmentLocation(fromFileName: fileName)
            let playingChapterIndex =
                location?.chapterIndex
                ?? NarrationFileNaming.chapterIndex(fromFileName: fileName)
            let segmentKey = location.map {
                ReaderActiveBlockResolver.segmentKey(
                    forChapter: $0.chapterIndex, segment: $0.segmentIndex)
            }
            let chapterIndices = ReaderActiveBlockResolver.trackChapterScope(
                trackCount: groups.count,
                isMultiM4B: isMultiM4B,
                currentIndex: index,
                playingChapterIndex: playingChapterIndex)
            return SlideshowTrackContext(
                title: group.title,
                duration: group.duration,
                segmentKey: segmentKey,
                chapterIndices: chapterIndices)
        }
    }

    // MARK: - Writer

    private func writeMovie(
        plan: SlideshowExportPlan,
        renderer: SlideshowFrameRenderer,
        audioComposition: AVComposition,
        to outputURL: URL,
        videoSettings: H264VideoSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // The preflighted settings ARE the encode settings — build the writer
        // input from `videoSettings.outputSettings`, and take the pixel-buffer /
        // renderer dimensions from the same value, so validation and encode are
        // guaranteed identical.
        let width = videoSettings.width
        let height = videoSettings.height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings.outputSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw ExportError.writerFailed
        }
        writer.add(videoInput)
        writer.add(audioInput)

        let reader = try AVAssetReader(asset: audioComposition)
        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioComposition.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        guard reader.canAdd(readerOutput) else { throw ExportError.writerFailed }
        reader.add(readerOutput)

        var completed = false
        defer {
            if !completed {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        guard writer.startWriting() else {
            throw Self.writerError(writer)
        }
        guard reader.startReading() else {
            throw Self.readerError(reader)
        }
        writer.startSession(atSourceTime: .zero)

        let videoBox = VideoPumpBox(
            input: videoInput, adaptor: adaptor, renderer: renderer)
        let audioBox = AudioPumpBox(
            input: audioInput, output: readerOutput, reader: reader)
        let writerBox = WriterStatusBox(writer)
        let frames = plan.frames

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for (index, frame) in frames.enumerated() {
                    try Task.checkCancellation()
                    guard let image = videoBox.renderer.render(frame),
                        let buffer = Self.pixelBuffer(
                            from: image,
                            pool: videoBox.adaptor.pixelBufferPool,
                            width: width,
                            height: height)
                    else {
                        throw ExportError.writerFailed
                    }
                    while !videoBox.input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writerBox.writer.status == .writing else {
                            throw Self.writerError(writerBox.writer)
                        }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard
                        videoBox.adaptor.append(
                            buffer,
                            withPresentationTime: CMTime(
                                seconds: frame.startTime, preferredTimescale: 600))
                    else {
                        throw Self.writerError(writerBox.writer)
                    }
                    onProgress(0.05 + 0.9 * Double(index + 1) / Double(frames.count))
                }
                videoBox.input.markAsFinished()
            }
            group.addTask {
                while let sampleBuffer = audioBox.output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    while !audioBox.input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writerBox.writer.status == .writing else {
                            throw Self.writerError(writerBox.writer)
                        }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard audioBox.input.append(sampleBuffer) else {
                        throw Self.writerError(writerBox.writer)
                    }
                }
                guard audioBox.reader.status == .completed else {
                    throw Self.readerError(audioBox.reader)
                }
                audioBox.input.markAsFinished()
            }
            try await group.waitForAll()
        }

        writer.endSession(
            atSourceTime: CMTime(seconds: plan.totalDuration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Self.writerError(writer)
        }
        completed = true
    }

    private static func pixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            if status != kCVReturnSuccess { buffer = nil }
        }
        if buffer == nil {
            let status = CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer)
            guard status == kCVReturnSuccess else { return nil }
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func normalizedRange(
        _ requested: Range<TimeInterval>?, totalDuration: TimeInterval
    ) -> Range<TimeInterval>? {
        guard let requested else { return nil }
        let lower = min(max(requested.lowerBound, 0), totalDuration)
        let upper = min(max(requested.upperBound, lower), totalDuration)
        return lower..<upper
    }

    private static func writerError(_ writer: AVAssetWriter) -> Error {
        // `writerFailed` is intentionally a fallback only. Disk/codec errors
        // supplied by AVFoundation remain available to callers.
        writer.error ?? ExportError.writerFailed
    }

    private static func readerError(_ reader: AVAssetReader) -> Error {
        // Keep the underlying media error whenever AVFoundation provides one.
        reader.error ?? ExportError.writerFailed
    }
}
