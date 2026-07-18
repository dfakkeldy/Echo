// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Synchronization
import Testing

@testable import Echo

@MainActor
struct VideoExportServiceTests {
    // MARK: - Track contexts

    @Test func narratedChapterFilesBecomeOneContextEachWithPlayerScope() throws {
        let items = [
            ExportItem(
                title: "Chapter 1",
                url: URL(fileURLWithPath: "/cache/book-ch1-v15-af.m4a"),
                timeRange: nil),
            ExportItem(
                title: "Chapter 2",
                url: URL(fileURLWithPath: "/cache/book-ch2-v15-af.m4a"),
                timeRange: nil),
        ]

        let contexts = VideoExportService.trackContexts(
            items: items, measuredDurations: [10, 20])

        #expect(contexts.count == 2)
        #expect(contexts[0].duration == 10)
        #expect(contexts[1].duration == 20)
        let expected0 = try #require(
            NarrationFileNaming.chapterIndex(fromFileName: items[0].url.lastPathComponent))
        let expected1 = try #require(
            NarrationFileNaming.chapterIndex(fromFileName: items[1].url.lastPathComponent))
        #expect(contexts[0].chapterIndices == [expected0])
        #expect(contexts[1].chapterIndices == [expected1])
    }

    @Test func narratedSegmentFileCarriesPlayerSegmentAndChapterScope() {
        let item = ExportItem(
            title: "Chapter 3",
            url: URL(fileURLWithPath: "/cache/book-ch3-s2-v15-af.m4a"),
            timeRange: nil)

        let contexts = VideoExportService.trackContexts(
            items: [item], measuredDurations: [7])

        #expect(contexts.count == 1)
        #expect(contexts[0].segmentKey == "3-2")
        #expect(contexts[0].chapterIndices == [3])
    }

    @Test func singleFileM4BSlicesCollapseToOneWholeFileContext() {
        let url = URL(fileURLWithPath: "/books/whole.m4b")
        let items = [
            ExportItem(
                title: "One",
                url: url,
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 30, preferredTimescale: 600))),
            ExportItem(
                title: "Two",
                url: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 30, preferredTimescale: 600),
                    duration: CMTime(seconds: 45, preferredTimescale: 600))),
        ]

        let contexts = VideoExportService.trackContexts(
            items: items, measuredDurations: [30, 45])

        #expect(contexts.count == 1)
        #expect(contexts[0].duration == 75)
        #expect(contexts[0].segmentKey == nil)
        #expect(contexts[0].chapterIndices == nil)
    }

    @Test func sameFileM4BAlignmentCompactsSourceStartsInItemOrder() {
        let url = URL(fileURLWithPath: "/books/whole.m4b")
        let items = [
            ExportItem(
                title: "Later first",
                url: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 6, preferredTimescale: 600),
                    duration: CMTime(seconds: 2, preferredTimescale: 600))),
            ExportItem(
                title: "Earlier second",
                url: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 2, preferredTimescale: 600),
                    duration: CMTime(seconds: 2, preferredTimescale: 600))),
        ]
        let timeline: [ReaderActiveBlockResolver.TimelineRow] = [
            (2, 4, "early", 0, nil),
            (6, 8, "late", 1, nil),
        ]
        let words: [ReaderActiveBlockResolver.WordRow] = [
            (2.5, 3, "early", 0),
            (6.5, 7, "late", 0),
        ]

        let compacted = VideoExportService.compactedAlignment(
            timeline: timeline,
            words: words,
            items: items,
            measuredDurations: [2, 2])

        #expect(compacted.timeline.map(\.blockID) == ["late", "early"])
        #expect(compacted.timeline.map(\.start) == [0, 2])
        #expect(compacted.timeline.map(\.end) == [2, 4])
        #expect(compacted.words.map(\.blockID) == ["late", "early"])
        #expect(compacted.words.map(\.start) == [0.5, 2.5])
        #expect(compacted.words.map(\.end) == [1, 3])
    }

    @Test func partialM4BSlicePreservesKaraokeWordOrdinals() {
        let url = URL(fileURLWithPath: "/books/whole.m4b")
        let compacted = VideoExportService.compactedAlignment(
            timeline: [(10, 15, "partial", 0, nil)],
            words: [
                (10, 11, "partial", 0),
                (11, 12, "partial", 1),
                (12, 13, "partial", 2),
                (13, 14, "partial", 3),
                (14, 15, "partial", 4),
            ],
            items: [
                ExportItem(
                    title: "Partial",
                    url: url,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: 12, preferredTimescale: 600),
                        duration: CMTime(seconds: 2, preferredTimescale: 600)))
            ],
            measuredDurations: [2])
        let block = EPubBlockRecord(
            id: "partial",
            audiobookID: "book",
            spineHref: "spine",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "zero one two three four",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil)

        let first = VisualListeningCueResolver.snapshot(
            blocks: [block],
            timeline: compacted.timeline,
            words: compacted.words,
            time: 0.5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(first.subtitleCue?.activeWordIndex == 2)
        #expect(first.subtitleCue?.alreadyHeardWordCount == 2)

        let second = VisualListeningCueResolver.snapshot(
            blocks: [block],
            timeline: compacted.timeline,
            words: compacted.words,
            time: 1.5,
            currentTrackSegmentKey: nil,
            currentTrackChapterIndices: nil,
            syncPoint: .begin)
        #expect(second.subtitleCue?.activeWordIndex == 3)
        #expect(second.subtitleCue?.alreadyHeardWordCount == 3)
    }

    @Test func looseMultiFileTracksUsePlayerPositionScope() {
        let contexts = VideoExportService.trackContexts(
            items: [
                ExportItem(
                    title: "One", url: URL(fileURLWithPath: "/books/one.mp3"),
                    timeRange: nil),
                ExportItem(
                    title: "Two", url: URL(fileURLWithPath: "/books/two.mp3"),
                    timeRange: nil),
            ],
            measuredDurations: [12, 14])

        #expect(contexts.map(\.chapterIndices) == [[0], [1]])
    }

    @Test func multiM4BTracksRemainWholeBookScopedLikePlayer() {
        let contexts = VideoExportService.trackContexts(
            items: [
                ExportItem(
                    title: "Volume One", url: URL(fileURLWithPath: "/books/one.m4b"),
                    timeRange: nil),
                ExportItem(
                    title: "Volume Two", url: URL(fileURLWithPath: "/books/two.m4b"),
                    timeRange: nil),
            ],
            measuredDurations: [60, 70])

        #expect(contexts.map(\.chapterIndices) == [nil, nil])
    }

    // MARK: - Source errors

    @Test func sourceCancellationIsNeverTranslatedToNoAudio() async {
        await #expect(throws: CancellationError.self) {
            _ = try await VideoExportService.sourceItems(from: CancellingSource())
        }
    }

    @Test func nonSemanticSourceErrorsRemainAvailableToCallers() async {
        await #expect(throws: FixtureSourceError.diskRead) {
            _ = try await VideoExportService.sourceItems(from: FailingSource())
        }
    }

    // MARK: - Integration

    #if os(iOS) || os(macOS)
        @Test func reportsNoAudioWhenTheBookHasNoLocalSource() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            let database = try DatabaseService(inMemory: ())
            try Self.seedBook(
                database: database,
                bookID: "video-no-audio",
                title: "No Audio",
                tracks: [],
                alignmentDuration: nil)

            do {
                _ = try await VideoExportService().exportVideo(
                    audiobookID: "video-no-audio",
                    bookTitle: "No Audio",
                    databaseWriter: database.writer,
                    cacheDirectory: workDirectory,
                    outputDirectory: workDirectory)
                Issue.record("Expected noAudio")
            } catch VideoExportService.ExportError.noAudio {
                // Expected semantic preflight failure.
            } catch {
                Issue.record("Expected noAudio, got \(error)")
            }
        }

        @Test func reportsNoAlignmentBeforeRendering() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let audioURL = workDirectory.appendingPathComponent("track.m4a")
            try await Self.writeToneFile(to: audioURL, seconds: 2)

            let database = try DatabaseService(inMemory: ())
            try Self.seedBook(
                database: database,
                bookID: "video-no-alignment",
                title: "No Alignment",
                tracks: [TrackSeed(title: "Chapter 1", url: audioURL, duration: 2)],
                alignmentDuration: nil)

            do {
                _ = try await VideoExportService().exportVideo(
                    audiobookID: "video-no-alignment",
                    bookTitle: "No Alignment",
                    databaseWriter: database.writer,
                    cacheDirectory: workDirectory,
                    outputDirectory: workDirectory)
                Issue.record("Expected noAlignment")
            } catch VideoExportService.ExportError.noAlignment {
                // Expected semantic preflight failure.
            } catch {
                Issue.record("Expected noAlignment, got \(error)")
            }
            for url in Self.namedOutputURLs(title: "No Alignment", in: workDirectory) {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }

        @Test func reportsNoAlignmentWhenEnabledM4BSliceHasNoRows() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let encodedAudioURL = workDirectory.appendingPathComponent("unaligned.m4a")
            try await Self.writeToneFile(to: encodedAudioURL, seconds: 2)
            let audioURL = workDirectory.appendingPathComponent("unaligned.m4b")
            try FileManager.default.moveItem(at: encodedAudioURL, to: audioURL)

            let database = try DatabaseService(inMemory: ())
            let bookID = "video-enabled-slice-no-alignment"
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                    arguments: [bookID, "Enabled Slice No Alignment", 2])
                var track = TrackRecord(
                    id: "t0",
                    audiobookID: bookID,
                    title: "Whole book",
                    duration: 2,
                    filePath: audioURL.absoluteString,
                    isEnabled: true,
                    sortOrder: 0,
                    playlistPosition: nil)
                try track.insert(db)
                for (index, seed) in [
                    ("Disabled", 0.0, 1.0, false),
                    ("Enabled", 1.0, 2.0, true),
                ].enumerated() {
                    var chapter = ChapterRecord(
                        id: nil,
                        audiobookID: bookID,
                        title: seed.0,
                        startSeconds: seed.1,
                        endSeconds: seed.2,
                        isEnabled: seed.3,
                        sortOrder: index,
                        playlistPosition: nil)
                    try chapter.insert(db)
                }
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text, chapter_index, is_hidden)
                        VALUES
                          ('disabled-only', ?, 's', 0, 0, 0, 'paragraph',
                           'Only the disabled slice is aligned.', 0, 0)
                        """,
                    arguments: [bookID])
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item
                          (id, audiobook_id, item_type, title, audio_start_time,
                           audio_end_time, epub_block_id, alignment_status)
                        VALUES
                          ('ti-disabled', ?, 'textSegment', 'Disabled',
                           0.0, 1.0, 'disabled-only', 'test')
                        """,
                    arguments: [bookID])
            }

            do {
                _ = try await VideoExportService().exportVideo(
                    audiobookID: bookID,
                    bookTitle: "Enabled Slice No Alignment",
                    databaseWriter: database.writer,
                    cacheDirectory: workDirectory,
                    outputDirectory: workDirectory,
                    mode: .simple,
                    syncPoint: .begin,
                    width: 320,
                    height: 180)
                Issue.record("Expected noAlignment")
            } catch VideoExportService.ExportError.noAlignment {
                // Expected after disabled source-time rows are projected away.
            } catch {
                Issue.record("Expected noAlignment, got \(error)")
            }
            for url in Self.namedOutputURLs(
                title: "Enabled Slice No Alignment", in: workDirectory)
            {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }

        @Test func effectiveRangeTrimsAudioAndRebasesVideoAndSRT() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let fixture = try await Self.makeAlignedFixture(
                in: workDirectory, bookID: "video-range", title: "Range Test", seconds: 4)

            let output = try await VideoExportService().exportVideo(
                audiobookID: fixture.bookID,
                bookTitle: fixture.title,
                databaseWriter: fixture.database.writer,
                cacheDirectory: workDirectory,
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180,
                range: 1..<3)

            let asset = AVURLAsset(url: output.videoURL)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 2) < 0.1)
            let timings = try await Self.videoSampleTimings(asset: asset)
            #expect(!timings.isEmpty)
            #expect(timings.contains { abs($0.presentationTime) < 0.01 })
            #expect(timings.contains { abs($0.presentationTime - 1) < 0.01 })
            #expect(
                zip(timings, timings.dropFirst()).allSatisfy {
                    lhs, rhs in lhs.presentationTime <= rhs.presentationTime
                })
            #expect(timings.allSatisfy { $0.presentationTime >= 0 && $0.endTime <= 2.01 })
            #expect(abs((timings.map(\.endTime).max() ?? 0) - 2) < 0.01)

            let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
            #expect(srt.contains("00:00:00,000 --> 00:00:01,000"))
            #expect(srt.contains("00:00:01,000 --> 00:00:02,000"))
            let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
            #expect(chapters.isEmpty)
        }

        @Test func disabledSameFileM4BChaptersKeepExportTimelinesAligned() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let encodedAudioURL = workDirectory.appendingPathComponent("source.m4a")
            try await Self.writeToneFile(to: encodedAudioURL, seconds: 8)
            let audioURL = workDirectory.appendingPathComponent("source.m4b")
            try FileManager.default.moveItem(at: encodedAudioURL, to: audioURL)

            let database = try DatabaseService(inMemory: ())
            let bookID = "video-disabled-m4b-slices"
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                    arguments: [bookID, "Disabled M4B Slices", 8])
                var track = TrackRecord(
                    id: "t0",
                    audiobookID: bookID,
                    title: "Whole book",
                    duration: 8,
                    filePath: audioURL.absoluteString,
                    isEnabled: true,
                    sortOrder: 0,
                    playlistPosition: nil)
                try track.insert(db)
                for (index, seed) in [
                    ("Disabled introduction", 0.0, 2.0, false),
                    ("First enabled", 2.0, 4.0, true),
                    ("Disabled middle", 4.0, 6.0, false),
                    ("Second enabled", 6.0, 8.0, true),
                ].enumerated() {
                    var chapter = ChapterRecord(
                        id: nil,
                        audiobookID: bookID,
                        title: seed.0,
                        startSeconds: seed.1,
                        endSeconds: seed.2,
                        isEnabled: seed.3,
                        sortOrder: index,
                        playlistPosition: nil)
                    try chapter.insert(db)
                }
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text, chapter_index, is_hidden)
                        VALUES
                          ('disabled-intro', ?, 's', 0, 0, 0, 'paragraph',
                           'Disabled introduction text.', 0, 0),
                          ('first-enabled', ?, 's', 0, 1, 1, 'paragraph',
                           'First enabled slice text.', 1, 0),
                          ('disabled-middle', ?, 's', 0, 2, 2, 'paragraph',
                           'Disabled middle text.', 2, 0),
                          ('second-enabled', ?, 's', 0, 3, 3, 'paragraph',
                           'Second enabled slice text.', 3, 0)
                        """,
                    arguments: [bookID, bookID, bookID, bookID])
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item
                          (id, audiobook_id, item_type, title, audio_start_time,
                           audio_end_time, epub_block_id, alignment_status)
                        VALUES
                          ('ti0', ?, 'textSegment', 'Disabled introduction',
                           0.0, 2.0, 'disabled-intro', 'test'),
                          ('ti1', ?, 'textSegment', 'First enabled',
                           2.0, 4.0, 'first-enabled', 'test'),
                          ('ti2', ?, 'textSegment', 'Disabled middle',
                           4.0, 6.0, 'disabled-middle', 'test'),
                          ('ti3', ?, 'textSegment', 'Second enabled',
                           6.0, 8.0, 'second-enabled', 'test')
                        """,
                    arguments: [bookID, bookID, bookID, bookID])
            }

            let output = try await VideoExportService().exportVideo(
                audiobookID: bookID,
                bookTitle: "Disabled M4B Slices",
                databaseWriter: database.writer,
                cacheDirectory: workDirectory,
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180)

            let asset = AVURLAsset(url: output.videoURL)
            #expect(abs(try await asset.load(.duration).seconds - 4) < 0.1)
            let audioTrack = try #require(
                try await asset.loadTracks(withMediaType: .audio).first)
            let audioRange = try await audioTrack.load(.timeRange)
            #expect(abs(audioRange.start.seconds) < 0.01)
            #expect(abs(audioRange.duration.seconds - 4) < 0.1)

            let timings = try await Self.videoSampleTimings(asset: asset)
            #expect(timings.contains { abs($0.presentationTime) < 0.01 })
            #expect(timings.contains { abs($0.presentationTime - 2) < 0.01 })
            #expect(abs((timings.map(\.endTime).max() ?? 0) - 4) < 0.01)

            let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
            #expect(srt.contains("00:00:00,000 --> 00:00:02,000"))
            #expect(srt.contains("First enabled slice text."))
            #expect(srt.contains("00:00:02,000 --> 00:00:04,000"))
            #expect(srt.contains("Second enabled slice text."))
            #expect(!srt.contains("Disabled introduction text."))
            #expect(!srt.contains("Disabled middle text."))

            let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
            #expect(chapters == "00:00:00 First enabled\n00:00:02 Second enabled\n")

            let rangedOutput = try await VideoExportService().exportVideo(
                audiobookID: bookID,
                bookTitle: "Disabled M4B Slices",
                databaseWriter: database.writer,
                cacheDirectory: workDirectory,
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180,
                range: 1..<3)
            let rangedAsset = AVURLAsset(url: rangedOutput.videoURL)
            #expect(abs(try await rangedAsset.load(.duration).seconds - 2) < 0.1)
            let rangedSRT = try String(contentsOf: rangedOutput.srtURL, encoding: .utf8)
            #expect(rangedSRT.contains("00:00:00,000 --> 00:00:01,000"))
            #expect(rangedSRT.contains("First enabled slice text."))
            #expect(rangedSRT.contains("00:00:01,000 --> 00:00:02,000"))
            #expect(rangedSRT.contains("Second enabled slice text."))
            #expect(!rangedSRT.contains("Disabled"))
            let rangedChapters = try String(
                contentsOf: rangedOutput.chaptersURL, encoding: .utf8)
            #expect(rangedChapters == "00:00:01 Second enabled\n")
        }

        @Test func progressIsMonotonicAndCompletesAtOne() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let fixture = try await Self.makeAlignedFixture(
                in: workDirectory, bookID: "video-progress", title: "Progress Test", seconds: 2)
            let progress = Mutex<[Double]>([])

            _ = try await VideoExportService().exportVideo(
                audiobookID: fixture.bookID,
                bookTitle: fixture.title,
                databaseWriter: fixture.database.writer,
                cacheDirectory: workDirectory,
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180,
                onProgress: { value in
                    progress.withLock { $0.append(value) }
                })

            let values = progress.withLock { $0 }
            #expect(values.count >= 3)
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(values.last == 1)
        }

        @Test func cancellationPropagatesAndLeavesNoNamedBundle() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let fixture = try await Self.makeAlignedFixture(
                in: workDirectory,
                bookID: "video-cancellation",
                title: "Cancellation Test",
                seconds: 4)
            let progress = Mutex<[Double]>([])

            await #expect(throws: CancellationError.self) {
                _ = try await VideoExportService().exportVideo(
                    audiobookID: fixture.bookID,
                    bookTitle: fixture.title,
                    databaseWriter: fixture.database.writer,
                    cacheDirectory: workDirectory,
                    outputDirectory: workDirectory,
                    mode: .simple,
                    syncPoint: .begin,
                    width: 320,
                    height: 180,
                    onProgress: { value in
                        progress.withLock { $0.append(value) }
                        if value < 1 {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
            }

            #expect(!progress.withLock { $0 }.isEmpty)
            let safeTitle = SafeFileName.sanitizeForFilename(fixture.title)
            for url in [
                workDirectory.appendingPathComponent("\(safeTitle).mp4"),
                workDirectory.appendingPathComponent("\(safeTitle).srt"),
                workDirectory.appendingPathComponent("\(safeTitle).chapters.txt"),
            ] {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }

        @Test func skipsAudioLessSourceBeforeAValidAudioTrack() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let videoOnlyURL = workDirectory.appendingPathComponent("video-only.mp4")
            let audioURL = workDirectory.appendingPathComponent("valid.m4a")
            try await Self.writeVideoOnlyFile(to: videoOnlyURL, seconds: 1)
            try await Self.writeToneFile(to: audioURL, seconds: 2)
            let database = try DatabaseService(inMemory: ())
            try Self.seedBook(
                database: database,
                bookID: "video-skip-audio-less",
                title: "Skip Audio Less",
                tracks: [
                    TrackSeed(title: "Video only", url: videoOnlyURL, duration: 1),
                    TrackSeed(title: "Valid audio", url: audioURL, duration: 2),
                ],
                alignmentDuration: 2)

            let output = try await VideoExportService().exportVideo(
                audiobookID: "video-skip-audio-less",
                bookTitle: "Skip Audio Less",
                databaseWriter: database.writer,
                cacheDirectory: workDirectory,
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180)

            let asset = AVURLAsset(url: output.videoURL)
            #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
            let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
            #expect(chapters == "00:00:00 Valid audio\n")
            #expect(!chapters.contains("Video only"))
            let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
            #expect(!srt.contains("Video only"))
        }

        @Test func exportsH264VideoAACAudioSRTAndChaptersFromSeededFixture() async throws {
            let workDirectory = try Self.makeWorkDirectory()
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let firstImageURL = workDirectory.appendingPathComponent("first-image.png")
            let secondImageURL = workDirectory.appendingPathComponent("second-image.png")
            try Self.writeSolidImage(
                to: firstImageURL,
                color: CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
            try Self.writeSolidImage(
                to: secondImageURL,
                color: CGColor(red: 0.05, green: 0.05, blue: 0.95, alpha: 1))
            let fixture = try await Self.makeAlignedFixture(
                in: workDirectory,
                bookID: "video-test-book",
                title: "Video Test Book",
                seconds: 4)
            try fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE epub_block SET sequence_index = 1, block_index = 1 WHERE id = 'b1'"
                )
                try db.execute(
                    sql: "UPDATE epub_block SET sequence_index = 3, block_index = 3 WHERE id = 'b2'"
                )
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, image_path, chapter_index, is_hidden)
                        VALUES
                          ('image1', ?, 's', 0, 0, 0, 'image', ?, 0, 0),
                          ('image2', ?, 's', 0, 2, 2, 'image', ?, 0, 0)
                        """,
                    arguments: [
                        fixture.bookID, firstImageURL.path,
                        fixture.bookID, secondImageURL.path,
                    ])
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item
                          (id, audiobook_id, item_type, title, audio_start_time,
                           audio_end_time, epub_block_id, alignment_status)
                        VALUES
                          ('ti-image1', ?, 'textSegment', 'First image',
                           0.0, 2.0, 'image1', 'test'),
                          ('ti-image2', ?, 'textSegment', 'Second image',
                           2.0, 4.0, 'image2', 'test')
                        """,
                    arguments: [fixture.bookID, fixture.bookID])
            }

            let output = try await VideoExportService().exportVideo(
                audiobookID: fixture.bookID,
                bookTitle: fixture.title,
                databaseWriter: fixture.database.writer,
                cacheDirectory: workDirectory.appendingPathComponent("no-cache"),
                outputDirectory: workDirectory,
                mode: .simple,
                syncPoint: .begin,
                width: 320,
                height: 180)

            #expect(FileManager.default.fileExists(atPath: output.videoURL.path))
            let asset = AVURLAsset(url: output.videoURL)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 4) < 0.5)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(videoTracks.count == 1)
            #expect(audioTracks.count == 1)
            let videoTrack = try #require(videoTracks.first)
            let audioTrack = try #require(audioTracks.first)
            let size = try await videoTrack.load(.naturalSize)
            #expect(abs(size.width) == 320)
            #expect(abs(size.height) == 180)
            let videoFormatDescriptions = try await videoTrack.load(.formatDescriptions)
            #expect(
                videoFormatDescriptions.contains {
                    CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
                })
            let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
            #expect(
                audioFormatDescriptions.contains {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mFormatID
                        == kAudioFormatMPEG4AAC
                })
            let timings = try await Self.videoSampleTimings(asset: asset)
            #expect(!timings.isEmpty)
            #expect(timings.contains { abs($0.presentationTime) < 0.01 })
            #expect(timings.contains { abs($0.presentationTime - 2) < 0.01 })
            #expect(
                zip(timings, timings.dropFirst()).allSatisfy {
                    lhs, rhs in lhs.presentationTime <= rhs.presentationTime
                })
            #expect(timings.allSatisfy { $0.presentationTime >= 0 && $0.endTime <= 4.01 })
            #expect(abs((timings.map(\.endTime).max() ?? 0) - 4) < 0.01)

            let plannedImageTransition = 2.0
            let decodedFrames = try await Self.decodedVideoFrames(asset: asset)
            let beforeTransition = try #require(
                decodedFrames.last { $0.presentationTime < plannedImageTransition - 0.01 })
            let atTransition = try #require(
                decodedFrames.first { $0.presentationTime >= plannedImageTransition - 0.01 })
            #expect(abs(beforeTransition.presentationTime) < 0.01)
            #expect(abs(atTransition.presentationTime - plannedImageTransition) < 0.01)
            #expect(Int(beforeTransition.red) > Int(beforeTransition.blue) + 80)
            #expect(Int(atTransition.blue) > Int(atTransition.red) + 80)
            #expect(
                abs(Int(beforeTransition.red) - Int(atTransition.red))
                    + abs(Int(beforeTransition.blue) - Int(atTransition.blue)) > 160)

            let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
            #expect(srt.contains("Opening words spoken aloud."))
            #expect(srt.contains("00:00:02,000 --> 00:00:04,000"))

            let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
            #expect(chapters == "00:00:00 Chapter 1\n")

            let locales = try await asset.load(.availableChapterLocales)
            let preferredLanguages = locales.isEmpty ? ["en"] : locales.map(\.identifier)
            let groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: preferredLanguages)
            if let firstGroup = groups.first {
                #expect(groups.count == 1)
                #expect(abs(firstGroup.timeRange.start.seconds) < 0.01)
            } else {
                // Chapter atoms are best effort for MP4; the sidecar is the
                // deterministic fallback contract.
                #expect(chapters == "00:00:00 Chapter 1\n")
            }
        }

        private struct Fixture {
            let database: DatabaseService
            let bookID: String
            let title: String
        }

        private struct TrackSeed {
            let title: String
            let url: URL
            let duration: Double
        }

        private struct SampleTiming {
            let presentationTime: Double
            let duration: Double

            var endTime: Double { presentationTime + duration }
        }

        private struct DecodedVideoFrame {
            let presentationTime: Double
            let red: UInt8
            let green: UInt8
            let blue: UInt8
        }

        private static func makeWorkDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static func namedOutputURLs(title: String, in directory: URL) -> [URL] {
            let safeTitle = SafeFileName.sanitizeForFilename(title)
            return [
                directory.appendingPathComponent("\(safeTitle).mp4"),
                directory.appendingPathComponent("\(safeTitle).srt"),
                directory.appendingPathComponent("\(safeTitle).chapters.txt"),
            ]
        }

        private static func makeAlignedFixture(
            in workDirectory: URL,
            bookID: String,
            title: String,
            seconds: Double
        ) async throws -> Fixture {
            let audioURL = workDirectory.appendingPathComponent("\(bookID).m4a")
            try await writeToneFile(to: audioURL, seconds: seconds)
            let database = try DatabaseService(inMemory: ())
            try seedBook(
                database: database,
                bookID: bookID,
                title: title,
                tracks: [TrackSeed(title: "Chapter 1", url: audioURL, duration: seconds)],
                alignmentDuration: seconds)
            return Fixture(database: database, bookID: bookID, title: title)
        }

        private static func seedBook(
            database: DatabaseService,
            bookID: String,
            title: String,
            tracks: [TrackSeed],
            alignmentDuration: Double?
        ) throws {
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                    arguments: [bookID, title, tracks.reduce(0) { $0 + $1.duration }])
                for (index, seed) in tracks.enumerated() {
                    var track = TrackRecord(
                        id: "t\(index)",
                        audiobookID: bookID,
                        title: seed.title,
                        duration: seed.duration,
                        filePath: seed.url.absoluteString,
                        isEnabled: true,
                        sortOrder: index,
                        playlistPosition: nil)
                    try track.insert(db)
                }
                guard let alignmentDuration else { return }
                let midpoint = alignmentDuration / 2
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text, chapter_index, is_hidden)
                        VALUES
                          ('b1', ?, 's', 0, 0, 0, 'paragraph',
                           'Opening words spoken aloud.', 0, 0),
                          ('b2', ?, 's', 0, 1, 1, 'paragraph',
                           'Closing words follow after.', 0, 0)
                        """,
                    arguments: [bookID, bookID])
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item
                          (id, audiobook_id, item_type, title, audio_start_time,
                           audio_end_time, epub_block_id, alignment_status)
                        VALUES
                          ('ti1', ?, 'textSegment', 'Opening', 0.0, ?, 'b1', 'test'),
                          ('ti2', ?, 'textSegment', 'Closing', ?, ?, 'b2', 'test')
                        """,
                    arguments: [
                        bookID, midpoint,
                        bookID, midpoint, alignmentDuration,
                    ])
            }
        }

        private static func videoSampleTimings(asset: AVAsset) async throws -> [SampleTiming] {
            let track = try #require(
                try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            try #require(reader.canAdd(output))
            reader.add(output)
            try #require(reader.startReading())

            var timings: [SampleTiming] = []
            while let sample = output.copyNextSampleBuffer() {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                guard presentationTime.isNumeric, duration.isNumeric, duration > .zero else {
                    continue
                }
                timings.append(
                    SampleTiming(
                        presentationTime: presentationTime.seconds,
                        duration: duration.seconds))
            }
            #expect(reader.status == .completed)
            return timings
        }

        private static func decodedVideoFrames(asset: AVAsset) async throws
            -> [DecodedVideoFrame]
        {
            let track = try #require(
                try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
            try #require(reader.canAdd(output))
            reader.add(output)
            try #require(reader.startReading())

            var frames: [DecodedVideoFrame] = []
            while let sample = output.copyNextSampleBuffer() {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                guard presentationTime.isNumeric,
                    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
                else { continue }
                frames.append(
                    try decodedCenterPixel(
                        from: pixelBuffer,
                        presentationTime: presentationTime.seconds))
            }
            #expect(reader.status == .completed)
            return frames
        }

        private static func decodedCenterPixel(
            from pixelBuffer: CVPixelBuffer,
            presentationTime: TimeInterval
        ) throws -> DecodedVideoFrame {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
                throw FixtureSourceError.videoFrameUnavailable
            }
            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                throw FixtureSourceError.videoFrameUnavailable
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw FixtureSourceError.videoFrameUnavailable
            }

            let x = CVPixelBufferGetWidth(pixelBuffer) / 2
            let y = CVPixelBufferGetHeight(pixelBuffer) / 2
            let offset = y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            return DecodedVideoFrame(
                presentationTime: presentationTime,
                red: bytes[offset + 2],
                green: bytes[offset + 1],
                blue: bytes[offset])
        }

        private static func writeSolidImage(to url: URL, color: CGColor) throws {
            let size = 96
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data: nil,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }

        /// Writes a real AAC audio file so `AVAssetReader` exercises its decode path.
        private static func writeToneFile(to url: URL, seconds: Double) async throws {
            let sampleRate = 44_100.0
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
            let frames = AVAudioFrameCount(sampleRate * seconds)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channel = try #require(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                channel[frame] =
                    sinf(2 * Float.pi * 440 * Float(frame) / Float(sampleRate)) * 0.2
            }
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ])
            try file.write(from: buffer)
        }

        private static func writeVideoOnlyFile(to url: URL, seconds: Double) async throws {
            let width = 64
            let height = 64
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            try #require(writer.canAdd(input))
            writer.add(input)
            try #require(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            try #require(
                CVPixelBufferCreate(
                    nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                    == kCVReturnSuccess)
            try #require(adaptor.append(try #require(buffer), withPresentationTime: .zero))
            input.markAsFinished()
            writer.endSession(
                atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
            await writer.finishWriting()
            try #require(writer.status == .completed)
        }
    #endif

    private enum FixtureSourceError: Error {
        case diskRead
        case videoFrameUnavailable
    }

    private struct CancellingSource: ExportSource {
        func items() async throws -> [ExportItem] {
            throw CancellationError()
        }
    }

    private struct FailingSource: ExportSource {
        func items() async throws -> [ExportItem] {
            throw FixtureSourceError.diskRead
        }
    }
}
