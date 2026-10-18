// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct PreparedNarrationPlaybackPlan {
    let manifest: AnthologyBuildManifest?
    let chapters: [NarrationChapterRenderPlan]
    let segments: [NarrationSegmentPlanner.PlannedSegment]
    let expectedDurableFileNames: Set<String>
    let expectedFileNamesByChapter: [Int: Set<String>]
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
        validateActive: () throws -> Void = { try Task.checkCancellation() },
        cleanup: (Set<String>) throws -> Void
    ) async throws -> PreparedNarrationPlaybackPlan {
        try validateActive()
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

        let activeChapterIndices = Set(renderPlans.map(\.chapterIndex))
        let excludedRenderPlans = allRenderPlans.filter {
            !activeChapterIndices.contains($0.chapterIndex)
        }
        let expectedSegments = segments + NarrationSegmentPlanner.plan(excludedRenderPlans)
        var expectedFileNames = Set<String>()
        var expectedFileNamesByChapter: [Int: Set<String>] = [:]
        for segment in expectedSegments {
            let fileName = try await expectedFileName(segment)
            try validateActive()
            guard expectedFileNames.insert(fileName).inserted else {
                throw NarrationPlaybackPlanPreparationError.duplicateExpectedFileName(fileName)
            }
            expectedFileNamesByChapter[segment.chapterIndex, default: []].insert(fileName)
        }

        let activeExpectedFileNamesByChapter = expectedFileNamesByChapter.filter {
            activeChapterIndices.contains($0.key)
        }
        let renderedChapterIndices = NarrationOutlineReadiness.renderedChapterIndices(
            expectedFileNamesByChapter: activeExpectedFileNamesByChapter,
            existingFileNames: existingDurableFileNames)

        try validateActive()
        try cleanup(expectedFileNames)
        return PreparedNarrationPlaybackPlan(
            manifest: manifest,
            chapters: renderPlans,
            segments: segments,
            expectedDurableFileNames: expectedFileNames,
            expectedFileNamesByChapter: expectedFileNamesByChapter,
            renderedChapterIndices: renderedChapterIndices)
    }
}
