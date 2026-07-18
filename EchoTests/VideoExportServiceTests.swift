// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
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

    // MARK: - Integration

    #if os(iOS) || os(macOS)
        @Test func exportsH264VideoAACAudioSRTAndChaptersFromSeededFixture() async throws {
            let workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            let audioURL = workDirectory.appendingPathComponent("track1.m4a")
            try await Self.writeToneFile(to: audioURL, seconds: 4)

            let database = try DatabaseService(inMemory: ())
            let bookID = "video-test-book"
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                    arguments: [bookID, "Video Test Book", 4])
                var track = TrackRecord(
                    id: "t1", audiobookID: bookID, title: "Chapter 1", duration: 4,
                    filePath: audioURL.absoluteString, isEnabled: true, sortOrder: 0,
                    playlistPosition: nil)
                try track.insert(db)
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
                          ('ti1', ?, 'textSegment', 'Opening', 0.0, 2.0, 'b1', 'test'),
                          ('ti2', ?, 'textSegment', 'Closing', 2.0, 4.0, 'b2', 'test')
                        """,
                    arguments: [bookID, bookID])
            }

            let output = try await VideoExportService().exportVideo(
                audiobookID: bookID,
                bookTitle: "Video Test Book",
                databaseWriter: database.writer,
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

            let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
            #expect(srt.contains("Opening words spoken aloud."))
            #expect(srt.contains("00:00:02,000 --> 00:00:04,000"))

            let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
            #expect(chapters == "00:00:00 Chapter 1\n")
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
    #endif
}
