import Foundation
import GRDB
import AVFoundation
import os.log

/// Generates a Dense Feed from M4B audio files + an EnhancedTranscript.json sidecar.
///
/// The EnhancedTranscript.json is produced offline by the `OrbitTranscriptionCLI align`
/// subcommand. It contains Whisper timestamps with EPUB structural markers injected.
///
/// Produces TimelineItem rows for:
/// - `track` — one per audio file
/// - `chapterMarker` — from M4B chapter metadata (audio) OR EPUB spine markers (text)
/// - `textSegment` — from the enhanced transcription segments
/// - `imageAsset` — from EPUB image markers and chapter artwork
///
/// The `epubReference` and `epubSequenceIndex` fields are populated from the enhanced
/// transcript data, enabling stable structural ordering even when audio timestamps overlap.
struct RichIngestionStrategy: IngestionStrategy {
    let name = "Rich"
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "RichIngestion")

    static func canHandle(folderURL: URL) -> Bool {
        let assets = IngestionFactory.detectAssets(in: folderURL)
        return !assets.audioFiles.isEmpty && assets.hasEnhancedTranscript
    }

    func ingest(folderURL: URL, into db: DatabaseWriter) async throws -> IngestionResult {
        let assets = IngestionFactory.detectAssets(in: folderURL)
        guard !assets.audioFiles.isEmpty else {
            throw IngestionError.noAudioFiles(folderURL: folderURL)
        }
        guard let enhancedJSON = assets.enhancedTranscriptJSON else {
            throw IngestionError.missingRequiredAsset("EnhancedTranscript.json")
        }

        let audiobookID = folderURL.absoluteString
        let title = folderURL.deletingPathExtension().lastPathComponent
        var totalDuration: TimeInterval = 0
        var itemCounts: [TimelineItemType: Int] = [:]

        // ── Clear existing data (idempotent) ──
        try await clearExisting(audiobookID: audiobookID, in: db)

        // ── Phase 1: Audio + chapters (same as AudioOnly) ──
        let audioResult = try await ingestAudioFiles(
            assets.audioFiles,
            audiobookID: audiobookID,
            folderURL: folderURL,
            into: db
        )
        totalDuration = audioResult.totalDuration

        // ── Phase 2: Enhanced transcription segments ──
        let segments = try loadEnhancedSegments(from: enhancedJSON)
        var transcriptionRecords: [TranscriptionRecord] = []
        var imageAssetRecords: [ImageAssetRecord] = []

        for (index, segment) in segments.enumerated() {
            transcriptionRecords.append(TranscriptionRecord(
                audiobookID: audiobookID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                epubReference: segment.epubReference,
                epubSequenceIndex: index
            ))

            // Extract image markers from the enhanced segment.
            if let markers = segment.markers {
                for marker in markers where marker.type == "image" {
                    // Look for the referenced image file in the EPUB extracted assets.
                    let imageName = marker.payload
                    let imagePath = findImageAsset(named: imageName, in: folderURL)
                    if let path = imagePath {
                        imageAssetRecords.append(ImageAssetRecord(
                            id: "\(audiobookID)-img-\(imageAssetRecords.count)",
                            audiobookID: audiobookID,
                            title: imageName,
                            imagePath: path,
                            mediaTimestamp: segment.startTime,
                            epubReference: marker.payload,
                            isEnabled: true,
                            playlistPosition: segment.startTime
                        ))
                    }
                }
            }
        }

        // ── Write to database ──
        try await db.write { db in
            for var segment in transcriptionRecords { try segment.insert(db) }
            for image in imageAssetRecords { try image.insert(db) }
        }

        itemCounts[.track] = audioResult.trackCount
        itemCounts[.chapterMarker] = audioResult.chapterCount
        itemCounts[.textSegment] = transcriptionRecords.count
        itemCounts[.imageAsset] = imageAssetRecords.count

        logger.info("Rich ingestion complete: \(itemCounts)")

        return IngestionResult(
            audiobookID: audiobookID,
            strategyName: name,
            title: title,
            duration: totalDuration,
            fileCount: audioResult.trackCount,
            itemCounts: itemCounts
        )
    }

    // MARK: - Audio File Ingestion (delegates to same logic as AudioOnly)

    private struct AudioIngestResult {
        let totalDuration: TimeInterval
        let trackCount: Int
        let chapterCount: Int
    }

    private func ingestAudioFiles(
        _ audioFiles: [URL],
        audiobookID: String,
        folderURL: URL,
        into db: DatabaseWriter
    ) async throws -> AudioIngestResult {
        // Reuse the AudioOnly strategy's audio/chapter ingestion logic.
        // In the full implementation, this calls into a shared helper rather
        // than duplicating the AudioOnlyIngestionStrategy code.
        //
        // For the skeleton: delegates to AudioOnlyIngestionStrategy for the
        // audio portion, then we layer transcription on top.
        let audioStrategy = AudioOnlyIngestionStrategy()
        let result = try await audioStrategy.ingest(folderURL: folderURL, into: db)
        return AudioIngestResult(
            totalDuration: result.duration,
            trackCount: result.fileCount,
            chapterCount: result.itemCounts[.chapterMarker] ?? 0
        )
    }

    // MARK: - Enhanced Transcript Loading

    /// Lightweight decodable mirror of EnhancedTranscriptionSegment from the CLI tool.
    /// Defined here to avoid depending on the OrbitEPUBAligner module at compile time.
    private struct EnhancedSegmentJSON: Codable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let epubReference: String?
        let epubSequenceIndex: Int?
        let markers: [MarkerJSON]?

        enum CodingKeys: String, CodingKey {
            case text, startTime, endTime
            case epubReference = "epub_reference"
            case epubSequenceIndex = "epub_sequence_index"
            case markers
        }
    }

    private struct MarkerJSON: Codable {
        let type: String
        let payload: String
    }

    private func loadEnhancedSegments(from url: URL) throws -> [EnhancedSegmentJSON] {
        let data = try Data(contentsOf: url)
        if let segments = try? JSONDecoder().decode([EnhancedSegmentJSON].self, from: data) {
            return segments
        }
        // Fallback: try decoding as a dictionary with a "segments" key.
        if let wrapper = try? JSONDecoder().decode([String: [EnhancedSegmentJSON]].self, from: data),
           let segments = wrapper["segments"] {
            return segments
        }
        throw IngestionError.missingRequiredAsset("Unable to parse EnhancedTranscript.json")
    }

    // MARK: - Image Asset Resolution

    /// Searches for an image file extracted from the EPUB in the folder.
    /// EPUB images are typically extracted alongside the enhanced transcript.
    private func findImageAsset(named name: String, in folderURL: URL) -> String? {
        let assetsDir = folderURL.appendingPathComponent("epub_assets")
        let candidates = [
            assetsDir.appendingPathComponent(name),
            folderURL.appendingPathComponent(name),
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        logger.warning("Image asset not found on disk: \(name)")
        return nil
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
