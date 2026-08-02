// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct PreparedNarrationPlaybackPlan {
    let manifest: AnthologyBuildManifest?
    let chapters: [NarrationChapterRenderPlan]
    let segments: [NarrationSegmentPlanner.PlannedSegment]
    let expectedDurableFileNames: Set<String>
    let renderedChapterIndices: Set<Int>

    var voiceOverrideCount: Int {
        guard let manifest else { return 0 }
        let representedKeys = Set(chapters.compactMap(\.sourceChapterKey))
        return manifest.chapters.count {
            $0.voiceID != nil && representedKeys.contains($0.entryID.uuidString)
        }
    }
}

enum NarrationPlaybackPlanPreparationError: Error, Equatable {
    case emptyRenderPlan
    case activeChapterMissingFromAll(Int)
    case duplicateExpectedFileName(String)
}

/// Orders the trusted preparation boundary used before narration mutates its
/// cache: receipt resolution, chapter validation, complete expected-set
/// computation, exact readiness, then cleanup.
@MainActor
enum NarrationPlaybackPlanPreparation {
    static func prepare(
        chapters: [NarrationChapterPlanner.PlannedChapter],
        allChapters: [NarrationChapterPlanner.PlannedChapter],
        preferredVoice: VoiceID,
        resolveManifest: () throws -> AnthologyBuildManifest?,
        existingDurableFileNames: Set<String>,
        expectedFileName: (NarrationSegmentPlanner.PlannedSegment) async throws -> String,
        cleanup: (Set<String>) throws -> Void
    ) async throws -> PreparedNarrationPlaybackPlan {
        let manifest = try resolveManifest()
        let allRenderPlans = try NarrationChapterRenderPlanner.plan(
            chapters: allChapters,
            preferredVoice: preferredVoice,
            manifest: manifest)
        let allPlansByChapterIndex = Dictionary(
            uniqueKeysWithValues: allRenderPlans.map { ($0.chapterIndex, $0) })
        let renderPlans = try chapters.map { chapter in
            guard let resolved = allPlansByChapterIndex[chapter.index] else {
                throw NarrationPlaybackPlanPreparationError.activeChapterMissingFromAll(
                    chapter.index)
            }
            return NarrationChapterRenderPlan(
                chapterIndex: chapter.index,
                displayNumber: chapter.displayNumber,
                sourceChapterKey: resolved.sourceChapterKey,
                title: chapter.title,
                blocks: chapter.blocks,
                voice: resolved.voice)
        }
        let segments = NarrationSegmentPlanner.plan(renderPlans)
        guard !segments.isEmpty else {
            throw NarrationPlaybackPlanPreparationError.emptyRenderPlan
        }

        var fileNamesBySegment: [(NarrationSegmentPlanner.PlannedSegment, String)] = []
        fileNamesBySegment.reserveCapacity(segments.count)
        var expectedFileNames = Set<String>()
        for segment in segments {
            let fileName = try await expectedFileName(segment)
            guard expectedFileNames.insert(fileName).inserted else {
                throw NarrationPlaybackPlanPreparationError.duplicateExpectedFileName(fileName)
            }
            fileNamesBySegment.append((segment, fileName))
        }

        let chapterIndices = Set(segments.map(\.chapterIndex))
        let renderedChapterIndices = Set(chapterIndices.filter { chapterIndex in
            fileNamesBySegment
                .filter { $0.0.chapterIndex == chapterIndex }
                .allSatisfy { existingDurableFileNames.contains($0.1) }
        })

        let activeChapterIndices = Set(renderPlans.map(\.chapterIndex))
        let excludedPlans = allRenderPlans.filter {
            !activeChapterIndices.contains($0.chapterIndex)
        }
        let preservedExcludedFileNames = existingDurableFileNames.filter { fileName in
            excludedPlans.contains { cacheFile(fileName, belongsTo: $0) }
        }
        let cleanupExpectedFileNames = expectedFileNames.union(preservedExcludedFileNames)

        try cleanup(cleanupExpectedFileNames)
        return PreparedNarrationPlaybackPlan(
            manifest: manifest,
            chapters: renderPlans,
            segments: segments,
            expectedDurableFileNames: cleanupExpectedFileNames,
            renderedChapterIndices: renderedChapterIndices)
    }

    private static func cacheFile(
        _ fileName: String,
        belongsTo plan: NarrationChapterRenderPlan
    ) -> Bool {
        let suffix = "-\(plan.voice.rawValue)-v\(NarrationFileNaming.renderVersion).m4a"
        guard fileName.hasSuffix(suffix),
            let location = NarrationFileNaming.location(fromFileName: fileName)
        else { return false }

        if let sourceChapterKey = plan.sourceChapterKey {
            return location.stableChapterToken
                == NarrationFileNaming.stableChapterToken(for: sourceChapterKey)
        }
        return location.chapterIndex == plan.chapterIndex
    }
}
