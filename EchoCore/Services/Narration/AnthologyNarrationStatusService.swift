// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

nonisolated struct AnthologyNarrationStatus: Equatable, Sendable {
    let readyChapterCount: Int
    let totalChapterCount: Int
    let staleSourceChapterKeys: [String]

    var isComplete: Bool {
        totalChapterCount > 0 && readyChapterCount == totalChapterCount
    }
}

nonisolated enum AnthologyNarrationReadinessError: Error, Equatable, Sendable {
    case invalidPlan
    case incomplete(chapterDisplayNumbers: [Int])
}

extension AnthologyNarrationReadinessError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidPlan:
            return String(
                localized: "Rebuild this anthology to refresh its narration plan, then try again."
            )
        case .incomplete(let chapterDisplayNumbers):
            let chapters = chapterDisplayNumbers.map(String.init).joined(separator: ", ")
            return String(localized: "Narration is incomplete for chapter(s) \(chapters).")
        }
    }
}

nonisolated struct AnthologyNarrationExportUnit: Sendable {
    let title: String
    let url: URL
    let sortOrder: Int
    let planOrder: Int
    let segmentIndex: Int?

    var exportItem: ExportItem {
        ExportItem(
            title: title,
            url: url,
            timeRange: nil,
            emitsChapterMarker: segmentIndex == nil || segmentIndex == 0)
    }
}

nonisolated struct AnthologyNarrationInventory: Sendable {
    let status: AnthologyNarrationStatus
    let missingChapterDisplayNumbers: [Int]
    let exportUnits: [AnthologyNarrationExportUnit]

    var exportItems: [ExportItem] {
        exportUnits
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                if $0.planOrder != $1.planOrder { return $0.planOrder < $1.planOrder }
                return ($0.segmentIndex ?? -1) < ($1.segmentIndex ?? -1)
            }
            .map(\.exportItem)
    }
}

/// Compares the current, validated anthology narration plan with the exact
/// persisted tracks and durable cache files that can satisfy it. Ordinary books
/// return `nil`, leaving their established filename-glob export path untouched.
struct AnthologyNarrationStatusService: Sendable {
    let db: DatabaseWriter
    let cacheDirectory: URL

    func status(
        audiobookID: String,
        preferredVoice: VoiceID
    ) async throws -> AnthologyNarrationStatus? {
        try await inventory(audiobookID: audiobookID, preferredVoice: preferredVoice)?.status
    }

    func inventory(
        audiobookID: String,
        preferredVoice: VoiceID
    ) async throws -> AnthologyNarrationInventory? {
        let manifest: AnthologyBuildManifest?
        do {
            manifest = try AnthologyNarrationManifestResolver(db: db).resolve(
                audiobookID: audiobookID)
        } catch is AnthologyBuildManifestValidationError {
            throw AnthologyNarrationReadinessError.invalidPlan
        }
        guard let manifest else { return nil }

        let visibleBlocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
        let chapterPlans: [NarrationChapterRenderPlan]
        do {
            chapterPlans = try NarrationChapterRenderPlanner.plan(
                chapters: NarrationChapterPlanner.plan(from: visibleBlocks),
                preferredVoice: preferredVoice,
                manifest: manifest)
        } catch is NarrationChapterRenderPlanError {
            throw AnthologyNarrationReadinessError.invalidPlan
        }

        let pronunciationInputs = await MainActor.run {
            (
                PronunciationOverrideStore.shared.overrides(forBookID: audiobookID),
                PronunciationOverrideStore.shared.occurrenceOverrides(forBookID: audiobookID),
                UserDefaults.standard.string(forKey: "narrationQAClassifier") ?? "auto" == "auto"
            )
        }
        let pronunciationPack = await EnglishPronunciationPack.bundledOrEmpty()
        let tracks = try TrackDAO(db: db).tracks(for: audiobookID)
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        var readyChapterCount = 0
        var staleSourceChapterKeys: [String] = []
        var missingChapterDisplayNumbers: [Int] = []
        var exportUnits: [AnthologyNarrationExportUnit] = []

        for (planOrder, chapter) in chapterPlans.enumerated() {
            guard let sourceChapterKey = chapter.sourceChapterKey else {
                throw AnthologyNarrationReadinessError.invalidPlan
            }

            let fullURL = expectedURL(
                audiobookID: audiobookID,
                chapter: chapter,
                segment: nil,
                pronunciationInputs: pronunciationInputs,
                pronunciationPack: pronunciationPack)
            let fullTrackID = NarrationFileNaming.trackID(
                audiobookID: audiobookID,
                chapterIndex: chapter.chapterIndex,
                sourceChapterKey: sourceChapterKey,
                segmentIndex: nil)
            let fullTrack = tracksByID[fullTrackID]
            let hasCurrentFullTrack =
                fullTrack.map {
                    isCurrent(
                        track: $0,
                        audiobookID: audiobookID,
                        expectedURL: fullURL,
                        expectedVoice: chapter.voice)
                } ?? false

            if hasCurrentFullTrack, let fullTrack {
                readyChapterCount += 1
                exportUnits.append(
                    AnthologyNarrationExportUnit(
                        title: chapter.title,
                        url: fullURL,
                        sortOrder: fullTrack.sortOrder,
                        planOrder: planOrder,
                        segmentIndex: nil))
                continue
            }

            let segments = NarrationSegmentPlanner.segments(
                for: chapter, isFirstChapterOfBook: planOrder == 0)
            var chapterSegmentUnits: [AnthologyNarrationExportUnit] = []
            chapterSegmentUnits.reserveCapacity(segments.count)
            var allSegmentsCurrent = !segments.isEmpty
            for segment in segments {
                let url = expectedURL(
                    audiobookID: audiobookID,
                    chapter: chapter,
                    segment: segment,
                    pronunciationInputs: pronunciationInputs,
                    pronunciationPack: pronunciationPack)
                let trackID = NarrationFileNaming.trackID(
                    audiobookID: audiobookID,
                    chapterIndex: chapter.chapterIndex,
                    sourceChapterKey: sourceChapterKey,
                    segmentIndex: segment.segmentIndex)
                guard let track = tracksByID[trackID],
                    isCurrent(
                        track: track,
                        audiobookID: audiobookID,
                        expectedURL: url,
                        expectedVoice: chapter.voice)
                else {
                    allSegmentsCurrent = false
                    continue
                }
                chapterSegmentUnits.append(
                    AnthologyNarrationExportUnit(
                        title: chapter.title,
                        url: url,
                        sortOrder: track.sortOrder,
                        planOrder: planOrder,
                        segmentIndex: segment.segmentIndex))
            }

            if allSegmentsCurrent, chapterSegmentUnits.count == segments.count {
                readyChapterCount += 1
                exportUnits.append(contentsOf: chapterSegmentUnits)
            } else {
                staleSourceChapterKeys.append(sourceChapterKey)
                missingChapterDisplayNumbers.append(chapter.displayNumber)
            }
        }

        return AnthologyNarrationInventory(
            status: AnthologyNarrationStatus(
                readyChapterCount: readyChapterCount,
                totalChapterCount: chapterPlans.count,
                staleSourceChapterKeys: staleSourceChapterKeys),
            missingChapterDisplayNumbers: missingChapterDisplayNumbers,
            exportUnits: exportUnits)
    }

    private func expectedURL(
        audiobookID: String,
        chapter: NarrationChapterRenderPlan,
        segment: NarrationSegmentPlanner.PlannedSegment?,
        pronunciationInputs: (
            PronunciationOverrides, PronunciationOccurrenceOverrides, Bool
        ),
        pronunciationPack: EnglishPronunciationPack
    ) -> URL {
        let blocks = segment?.blocks ?? chapter.blocks
        let signature = NarrationService.contentSignature(
            for: blocks,
            includeLeadOutPad: segment == nil,
            overrides: pronunciationInputs.0,
            occurrenceOverrides: pronunciationInputs.1,
            normalizationMode: NarrationService.normalizationMode(
                fmEnabled: pronunciationInputs.2),
            pronunciationPack: pronunciationPack)
        let fileName: String
        if let segment {
            fileName = NarrationFileNaming.segmentFileName(
                audiobookID: audiobookID,
                chapterIndex: chapter.chapterIndex,
                sourceChapterKey: chapter.sourceChapterKey,
                segmentIndex: segment.segmentIndex,
                voice: chapter.voice,
                contentSignature: signature)
        } else {
            fileName = NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID,
                chapterIndex: chapter.chapterIndex,
                sourceChapterKey: chapter.sourceChapterKey,
                voice: chapter.voice,
                contentSignature: signature)
        }
        return cacheDirectory.appendingPathComponent(fileName)
    }

    private func isCurrent(
        track: TrackRecord,
        audiobookID: String,
        expectedURL: URL,
        expectedVoice: VoiceID
    ) -> Bool {
        guard track.audiobookID == audiobookID,
            track.narrationVoice == expectedVoice.rawValue,
            track.filePath == expectedURL.path
        else { return false }
        return (try? expectedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
