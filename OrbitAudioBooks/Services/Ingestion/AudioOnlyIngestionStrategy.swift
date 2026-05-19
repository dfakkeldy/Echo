import Foundation
import GRDB
import AVFoundation
import os.log

/// Generates a Sparse Feed from M4B/M4A audio files only.
///
/// Produces TimelineItem rows for:
/// - `track` — one per audio file
/// - `chapterMarker` — from M4B chapter metadata
/// - `imageAsset` — from chapter-level embedded artwork
///
/// Bookmark, ankiCard, and note rows are user-generated later and not part of ingestion.
struct AudioOnlyIngestionStrategy: IngestionStrategy {
    let name = "AudioOnly"
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "AudioOnlyIngestion")

    static func canHandle(folderURL: URL) -> Bool {
        let assets = IngestionFactory.detectAssets(in: folderURL)
        return !assets.audioFiles.isEmpty && !assets.hasEnhancedTranscript
    }

    func ingest(folderURL: URL, into db: DatabaseWriter) async throws -> IngestionResult {
        let assets = IngestionFactory.detectAssets(in: folderURL)
        guard !assets.audioFiles.isEmpty else {
            throw IngestionError.noAudioFiles(folderURL: folderURL)
        }

        let audiobookID = folderURL.absoluteString
        let title = folderURL.deletingPathExtension().lastPathComponent
        var totalDuration: TimeInterval = 0
        var itemCounts: [TimelineItemType: Int] = [:]

        // ── Clear existing data for this audiobook (idempotent) ──
        try await clearExisting(audiobookID: audiobookID, in: db)

        // ── Phase 1: Parse audio files ──
        var trackRecords: [TrackRecord] = []
        var allChapterRecords: [ChapterRecord] = []
        var allImageAssetRecords: [ImageAssetRecord] = []

        // Sort by filename for consistent ordering.
        let sortedAudioFiles = assets.audioFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var cumulativeOffset: TimeInterval = 0
        var fileCount = 0

        for audioURL in sortedAudioFiles {
            let asset = AVAsset(url: audioURL)
            let fileDuration: TimeInterval
            do {
                let cmDuration = try await asset.load(.duration)
                fileDuration = cmDuration.seconds.isFinite ? cmDuration.seconds : 0
            } catch {
                logger.error("Failed to load duration for \(audioURL.lastPathComponent): \(error.localizedDescription)")
                fileDuration = 0
            }

            let trackID = audioURL.absoluteString
            let trackTitle = audioURL.deletingPathExtension().lastPathComponent

            trackRecords.append(TrackRecord(
                id: trackID,
                audiobookID: audiobookID,
                title: trackTitle,
                duration: fileDuration,
                filePath: audioURL.path,
                isEnabled: true,
                sortOrder: fileCount,
                playlistPosition: Double(cumulativeOffset)
            ))

            // ── Parse chapters ──
            let chapters = await ChapterService.parseChapters(from: asset)
            for (idx, chapter) in chapters.enumerated() {
                allChapterRecords.append(ChapterRecord(
                    audiobookID: audiobookID,
                    title: chapter.title ?? "Chapter \(idx + 1)",
                    startSeconds: cumulativeOffset + chapter.startSeconds,
                    endSeconds: cumulativeOffset + chapter.endSeconds,
                    isEnabled: true,
                    sortOrder: allChapterRecords.count,
                    playlistPosition: Double(cumulativeOffset + chapter.startSeconds)
                ))
            }

            // ── Extract chapter artwork ──
            let artworkByIndex = await ChapterImageExtractor.extract(from: asset)
            for (chapterIndex, imageData) in artworkByIndex {
                guard chapterIndex < chapters.count else { continue }
                let chapter = chapters[chapterIndex]
                let chapterTitle = chapter.title ?? "Chapter \(chapterIndex + 1)"
                let timestamp = cumulativeOffset + chapter.startSeconds

                let path: String
                do {
                    path = try saveArtwork(imageData, withName: chapterTitle, in: folderURL)
                } catch {
                    logger.error("Failed to save artwork for '\(chapterTitle)': \(error.localizedDescription)")
                    continue
                }
                allImageAssetRecords.append(ImageAssetRecord(
                    id: "\(audiobookID)-img-\(allImageAssetRecords.count)",
                    audiobookID: audiobookID,
                    title: chapterTitle,
                    imagePath: path,
                    mediaTimestamp: timestamp,
                    epubReference: nil,
                    isEnabled: true,
                    playlistPosition: timestamp
                ))
            }

            cumulativeOffset += fileDuration
            fileCount += 1
        }

        totalDuration = cumulativeOffset

        // ── Write to database ──
        try await db.write { db in
            var audiobookRecord = AudiobookRecord(
                id: audiobookID,
                title: title,
                author: nil,
                duration: totalDuration,
                fileCount: fileCount,
                addedAt: Date().ISO8601Format()
            )
            try audiobookRecord.insert(db)

            for var track in trackRecords { try track.insert(db) }
            for var chapter in allChapterRecords { try chapter.insert(db) }
            for var image in allImageAssetRecords { try image.insert(db) }
        }

        itemCounts[.track] = trackRecords.count
        itemCounts[.chapterMarker] = allChapterRecords.count
        itemCounts[.imageAsset] = allImageAssetRecords.count

        logger.info("AudioOnly ingestion complete: \(itemCounts)")

        return IngestionResult(
            audiobookID: audiobookID,
            strategyName: name,
            title: title,
            duration: totalDuration,
            fileCount: fileCount,
            itemCounts: itemCounts
        )
    }

    private func saveArtwork(_ data: Data, withName name: String, in folderURL: URL) throws -> String {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let fileName = "chapter_artwork_\(safeName).jpg"
        let fileURL = folderURL.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL.path
    }

    // MARK: - Helpers

    private func clearExisting(audiobookID: String, in db: DatabaseWriter) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM image_asset WHERE audiobook_id = ?", arguments: [audiobookID])
            try db.execute(sql: "DELETE FROM chapter WHERE audiobook_id = ?", arguments: [audiobookID])
            try db.execute(sql: "DELETE FROM track WHERE audiobook_id = ?", arguments: [audiobookID])
            try db.execute(sql: "DELETE FROM transcription_segment WHERE audiobook_id = ?", arguments: [audiobookID])
            try db.execute(sql: "DELETE FROM audiobook WHERE id = ?", arguments: [audiobookID])
        }
    }
}
