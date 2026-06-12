import Foundation
import AVFoundation

// MARK: - Ingestion Error

enum IngestionError: Error, LocalizedError {
    case noAudioFiles(folderURL: URL)
    case missingRequiredAsset(String)
    case databaseError(Error)

    var errorDescription: String? {
        switch self {
        case .noAudioFiles(let url):
            return "No M4B or M4A files found in \(url.lastPathComponent)"
        case .missingRequiredAsset(let name):
            return "Required asset not found: \(name)"
        case .databaseError(let error):
            return "Database error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Ingestion Strategy

protocol TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?,
        epubBlocks: [EPubBlockRecord]?,
        alignmentAnchors: [AlignmentAnchorRecord]?,
        bookmarks: [TimelineItem]?,
        flashcards: [TimelineItem]?
    ) async throws -> [TimelineItem]
}

// MARK: - Factory

struct TimelineIngestionFactory {
    let strategy: TimelineIngestionStrategy

    static func strategy(
        hasTranscript: Bool,
        hasEnhancedTranscript: Bool,
        hasEPUB: Bool
    ) -> TimelineIngestionStrategy {
        if hasEPUB {
            return EPUBBlockIngestionStrategy()
        }
        if hasEnhancedTranscript || hasTranscript {
            return RichIngestionStrategy()
        }
        return SparseIngestionStrategy()
    }
}

// MARK: - EPUB Block Strategy (V1 Primary Path)

struct EPUBBlockIngestionStrategy: TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?,
        epubBlocks: [EPubBlockRecord]?,
        alignmentAnchors: [AlignmentAnchorRecord]?,
        bookmarks: [TimelineItem]?,
        flashcards: [TimelineItem]?
    ) async throws -> [TimelineItem] {
        var items: [TimelineItem] = []

        let anchorByBlockID: [String: AlignmentAnchorRecord] = {
            guard let anchors = alignmentAnchors else { return [:] }
            return Dictionary(anchors.map { ($0.epubBlockID, $0) }, uniquingKeysWith: { first, _ in first })
        }()

        // 1. Chapter markers
        for chapter in chapters {
            items.append(TimelineItem(
                id: "chapterMarker-\(audiobookID)-\(chapter.index)",
                audiobookID: audiobookID,
                itemType: .chapterMarker,
                title: chapter.title ?? "Chapter \(chapter.index + 1)",
                subtitle: nil,
                textPayload: nil,
                imagePath: nil,
                audioStartTime: chapter.startSeconds,
                audioEndTime: chapter.endSeconds,
                epubSequenceIndex: nil,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: chapter.isEnabled,
                sourceTable: "chapter",
                sourceRowid: String(chapter.index),
                metadataJSON: nil,
                epubBlockID: nil,
                timestampSource: TimestampSource.estimated.rawValue,
                alignmentStatus: AlignmentStatus.estimated.rawValue,
                alignmentConfidence: nil,
                createdAt: nil,
                modifiedAt: nil
            ))
        }

        // 2. EPUB blocks → timeline items (preferred feed source)
        if let blocks = epubBlocks {
            for block in blocks {
                var item = TimelineItem.fromEPubBlock(block, audiobookID: audiobookID)
                if let anchor = anchorByBlockID[block.id] {
                    item.audioStartTime = anchor.audioTime
                    item.audioEndTime = anchor.audioEndTime
                    item.timestampSource = TimestampSource.lockedAnchor.rawValue
                    item.alignmentStatus = AlignmentStatus.lockedAnchor.rawValue
                    item.alignmentConfidence = 1.0
                }
                items.append(item)
            }
        }

        // 3. Bookmarks (inline)
        if let bookmarks {
            for var bm in bookmarks {
                bm.audiobookID = audiobookID
                items.append(bm)
            }
        }

        // 4. Flashcards (inline)
        if let flashcards {
            for var fc in flashcards {
                fc.audiobookID = audiobookID
                items.append(fc)
            }
        }

        // Sort: timestamped items by audioStartTime, untimestamped by epubSequenceIndex.
        items.sort { a, b in
            let aTS = a.isTimestamped
            let bTS = b.isTimestamped
            if aTS && bTS {
                return a.audioStartTime < b.audioStartTime
            }
            if !aTS && !bTS {
                return (a.epubSequenceIndex ?? Int.max) < (b.epubSequenceIndex ?? Int.max)
            }
            return aTS
        }

        return items
    }
}

// MARK: - Rich Strategy (Transcript)

struct RichIngestionStrategy: TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?,
        epubBlocks: [EPubBlockRecord]? = nil,
        alignmentAnchors: [AlignmentAnchorRecord]? = nil,
        bookmarks: [TimelineItem]? = nil,
        flashcards: [TimelineItem]? = nil
    ) async throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var sequenceIndex = 0

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
                epubBlockID: nil,
                timestampSource: TimestampSource.estimated.rawValue,
                alignmentStatus: AlignmentStatus.estimated.rawValue,
                alignmentConfidence: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            items.append(item)
            sequenceIndex += 1
        }

        if let enhanced = enhancedTranscript, !enhanced.isEmpty {
            for segment in enhanced {
                let item = TimelineItem(
                    id: "textSegment-\(audiobookID)-\(segment.startTime ?? 0)-\(segment.endTime ?? 0)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: segment.text,
                    subtitle: nil,
                    textPayload: segment.text,
                    imagePath: nil,
                    audioStartTime: segment.startTime ?? -1,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: sequenceIndex,
                    granularityLevel: .sentence,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "transcription_segment",
                    sourceRowid: segment.id,
                    metadataJSON: encodeMarkers(segment.markers),
                    epubBlockID: nil,
                    timestampSource: segment.startTime != nil ? TimestampSource.transcript.rawValue : TimestampSource.none.rawValue,
                    alignmentStatus: segment.startTime != nil ? AlignmentStatus.lockedAnchor.rawValue : AlignmentStatus.unaligned.rawValue,
                    alignmentConfidence: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                items.append(item)
                sequenceIndex += 1

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
                            audioStartTime: segment.startTime ?? -1,
                            audioEndTime: segment.endTime,
                            epubSequenceIndex: sequenceIndex,
                            granularityLevel: .sentence,
                            playlistPosition: nil,
                            isEnabled: true,
                            sourceTable: "transcription_segment",
                            sourceRowid: segment.id,
                            metadataJSON: nil,
                            epubBlockID: nil,
                            timestampSource: segment.startTime != nil ? TimestampSource.transcript.rawValue : TimestampSource.none.rawValue,
                            alignmentStatus: segment.startTime != nil ? AlignmentStatus.lockedAnchor.rawValue : AlignmentStatus.unaligned.rawValue,
                            alignmentConfidence: nil,
                            createdAt: nil,
                            modifiedAt: nil
                        )
                        items.append(imageItem)
                        sequenceIndex += 1
                    }
                }
            }
        } else if let plain = transcript, !plain.isEmpty {
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
                    epubBlockID: nil,
                    timestampSource: TimestampSource.transcript.rawValue,
                    alignmentStatus: AlignmentStatus.lockedAnchor.rawValue,
                    alignmentConfidence: nil,
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

struct SparseIngestionStrategy: TimelineIngestionStrategy {
    func ingest(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?,
        epubBlocks: [EPubBlockRecord]? = nil,
        alignmentAnchors: [AlignmentAnchorRecord]? = nil,
        bookmarks: [TimelineItem]? = nil,
        flashcards: [TimelineItem]? = nil
    ) async throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var sequenceIndex = 0

        let asset = AVURLAsset(url: audioURL)
        let chapterImages = await ChapterImageExtractor.extractChapterArtwork(from: asset)

        for chapter in chapters {
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
                epubBlockID: nil,
                timestampSource: TimestampSource.estimated.rawValue,
                alignmentStatus: AlignmentStatus.estimated.rawValue,
                alignmentConfidence: nil,
                createdAt: nil,
                modifiedAt: nil
            )
            items.append(markerItem)
            sequenceIndex += 1

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
                    epubBlockID: nil,
                    timestampSource: TimestampSource.estimated.rawValue,
                    alignmentStatus: AlignmentStatus.estimated.rawValue,
                    alignmentConfidence: nil,
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

        let safeName = SafeFileName.fromAudiobookID(audiobookID)
        let filename = "\(safeName)_ch\(chapterIndex).jpg"
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
            // Chapter artwork is best-effort; failures are silent.
        }

        return result
    }
}
