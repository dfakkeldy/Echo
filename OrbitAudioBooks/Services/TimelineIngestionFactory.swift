import Foundation
import AVFoundation

// MARK: - Ingestion Strategy

/// Produces [TimelineItem] rows for the materialized timeline_item table
/// based on what assets the user has available.
protocol TimelineIngestionStrategy {
    /// Generate timeline items for the given audiobook and chapter data.
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?
    ) async throws -> [TimelineItem]
}

// MARK: - Factory

struct TimelineIngestionFactory {
    let strategy: TimelineIngestionStrategy

    /// Returns the appropriate strategy based on available assets.
    static func strategy(
        hasTranscript: Bool,
        hasEnhancedTranscript: Bool,
        hasEPUB: Bool
    ) -> TimelineIngestionStrategy {
        if hasEnhancedTranscript || hasTranscript {
            return RichIngestionStrategy()
        }
        return SparseIngestionStrategy()
    }
}

// MARK: - Rich Strategy (EPUB + Transcript)

/// Dense feed: transcription segments interleaved with EPUB structural markers.
struct RichIngestionStrategy: TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?
    ) async throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var sequenceIndex = 0

        // 1. Chapter markers from M4B metadata (or EPUB headings)
        for chapter in chapters {
            let item = TimelineItem(
                id: "chapterMarker-\(audiobookID)-\(chapter.index)",
                audiobookID: audiobookID,
                itemType: .chapterMarker,
                title: chapter.title ?? "Chapter \(chapter.index + 1)",
                subtitle: nil,
                textPayload: nil,
                imagePath: nil,
                audioStartTime: chapter.startSeconds,
                audioEndTime: chapter.endSeconds,
                epubSequenceIndex: sequenceIndex,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: chapter.isEnabled,
                sourceTable: "chapter",
                sourceRowid: String(chapter.index),
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            items.append(item)
            sequenceIndex += 1
        }

        // 2. Enhanced transcription segments (EPUB-aligned, with markers)
        if let enhanced = enhancedTranscript, !enhanced.isEmpty {
            for segment in enhanced {
                let item = TimelineItem(
                    id: "textSegment-\(audiobookID)-\(segment.startTime)-\(segment.endTime)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: segment.text,
                    subtitle: nil,
                    textPayload: segment.text,
                    imagePath: nil,
                    audioStartTime: segment.startTime,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: sequenceIndex,
                    granularityLevel: .sentence,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "transcription_segment",
                    sourceRowid: segment.id,
                    metadataJSON: encodeMarkers(segment.markers),
                    createdAt: nil,
                    modifiedAt: nil
                )
                items.append(item)
                sequenceIndex += 1

                // 3. Image assets from EPUB inline images
                if let markers = segment.markers {
                    for marker in markers where marker.type == .image {
                        let imageItem = TimelineItem(
                            id: "imageAsset-epub-\(audiobookID)-\(marker.epubCharOffset)",
                            audiobookID: audiobookID,
                            itemType: .imageAsset,
                            title: marker.payload,
                            subtitle: "EPUB Image",
                            textPayload: nil,
                            imagePath: marker.payload,
                            audioStartTime: segment.startTime,
                            audioEndTime: segment.endTime,
                            epubSequenceIndex: sequenceIndex,
                            granularityLevel: .sentence,
                            playlistPosition: nil,
                            isEnabled: true,
                            sourceTable: "transcription_segment",
                            sourceRowid: segment.id,
                            metadataJSON: nil,
                            createdAt: nil,
                            modifiedAt: nil
                        )
                        items.append(imageItem)
                        sequenceIndex += 1
                    }
                }
            }
        } else if let plain = transcript, !plain.isEmpty {
            // Fallback: plain transcription segments (no EPUB alignment)
            for segment in plain {
                let item = TimelineItem(
                    id: "textSegment-\(audiobookID)-\(segment.startTime)-\(segment.endTime)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: segment.text,
                    subtitle: nil,
                    textPayload: segment.text,
                    imagePath: nil,
                    audioStartTime: segment.startTime,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: sequenceIndex,
                    granularityLevel: .sentence,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "transcription_segment",
                    sourceRowid: segment.id,
                    metadataJSON: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                items.append(item)
                sequenceIndex += 1
            }
        }

        return items
    }

    private func encodeMarkers(_ markers: [SyncMarker]?) -> String? {
        guard let markers, !markers.isEmpty else { return nil }
        let encodable = markers.map {
            ["type": $0.type.rawValue, "payload": $0.payload, "epubCharOffset": $0.epubCharOffset]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encodable),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return nil
    }
}

// MARK: - Sparse Strategy (Audio-Only)

/// Sparse feed: chapter markers and chapter artwork only.
/// No transcription, no EPUB text.
struct SparseIngestionStrategy: TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?
    ) async throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var sequenceIndex = 0

        // Extract chapter artwork from M4B chapter metadata
        let asset = AVURLAsset(url: audioURL)
        let chapterImages = await ChapterImageExtractor.extractChapterArtwork(from: asset)

        for chapter in chapters {
            // Chapter marker
            let markerItem = TimelineItem(
                id: "chapterMarker-\(audiobookID)-\(chapter.index)",
                audiobookID: audiobookID,
                itemType: .chapterMarker,
                title: chapter.title ?? "Chapter \(chapter.index + 1)",
                subtitle: formatDuration(chapter.endSeconds - chapter.startSeconds),
                textPayload: nil,
                imagePath: nil,
                audioStartTime: chapter.startSeconds,
                audioEndTime: chapter.endSeconds,
                epubSequenceIndex: sequenceIndex,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: chapter.isEnabled,
                sourceTable: "chapter",
                sourceRowid: String(chapter.index),
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            items.append(markerItem)
            sequenceIndex += 1

            // Chapter artwork (if available)
            if let imageData = chapterImages[chapter.index],
               let savedPath = saveChapterImage(imageData, audiobookID: audiobookID, chapterIndex: chapter.index) {
                let imageItem = TimelineItem(
                    id: "imageAsset-chapter-\(audiobookID)-\(chapter.index)",
                    audiobookID: audiobookID,
                    itemType: .imageAsset,
                    title: chapter.title ?? "Chapter \(chapter.index + 1) Artwork",
                    subtitle: "Chapter Image",
                    textPayload: nil,
                    imagePath: savedPath,
                    audioStartTime: chapter.startSeconds,
                    audioEndTime: chapter.endSeconds,
                    epubSequenceIndex: sequenceIndex,
                    granularityLevel: .chapter,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "chapter",
                    sourceRowid: String(chapter.index),
                    metadataJSON: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                items.append(imageItem)
                sequenceIndex += 1
            }
        }

        return items
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func saveChapterImage(_ data: Data, audiobookID: String, chapterIndex: Int) -> String? {
        guard let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("ChapterArtwork") else { return nil }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let filename = "\(audiobookID)_ch\(chapterIndex).jpg"
        let url = cacheDir.appendingPathComponent(filename)

        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}

// MARK: - Chapter Image Extractor

enum ChapterImageExtractor {
    /// Extracts per-chapter artwork from M4B chapter metadata groups.
    /// Returns a dictionary keyed by chapter index (0-based, matching parsing order).
    static func extractChapterArtwork(from asset: AVAsset) async -> [Int: Data] {
        var result: [Int: Data] = [:]

        do {
            let locales = try await asset.load(.availableChapterLocales)
            let locale = locales.first ?? Locale.current
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyArtwork]
            )

            for (index, group) in groups.enumerated() {
                for item in group.items where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.dataValue) {
                        result[index] = data
                    }
                }
            }
        } catch {
            // Chapter artwork extraction is best-effort; failures are silent
        }

        return result
    }
}
