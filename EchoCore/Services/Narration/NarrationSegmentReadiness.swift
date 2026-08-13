// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationSegmentReadiness {
    enum Error: Swift.Error, Equatable {
        case mixedChapter(expected: Int, actual: Int)
        case mismatchedDisplayNumber(expected: Int, actual: Int)
        case nonContiguousPlan(expected: Int, actual: Int)
        case duplicateRenderedSegment(segmentIndex: Int)
        case mismatchedRenderedChapter(segmentIndex: Int, expected: Int, actual: Int)
        case mismatchedRenderedDisplayNumber(segmentIndex: Int, expected: Int, actual: Int)
        case mismatchedRenderedSegmentIndex(expected: Int, actual: Int?)
        case mismatchedSpokenBlocks(segmentIndex: Int, expected: [String], actual: [String])
    }

    static func assembledChapter(
        for plannedSegments: [NarrationSegmentPlanner.PlannedSegment],
        renderedSegments: [NarrationService.RenderedNarrationFile],
        files: [URL],
        audiobookID: String,
        voice: VoiceID,
        contentSignaturesBySegmentIndex: [Int: String] = [:],
        leadOutPadSeconds: TimeInterval = NarrationService.leadOutPadSeconds
    ) throws -> NarrationSegmentAssembly.AssembledChapter? {
        guard let firstPlan = plannedSegments.first else { return nil }
        let orderedPlans = try validate(plannedSegments, firstPlan: firstPlan)
        guard
            let cached = NarrationSegmentCache.cachedChapter(
                for: orderedPlans,
                files: files,
                audiobookID: audiobookID,
                voice: voice,
                contentSignaturesBySegmentIndex: contentSignaturesBySegmentIndex)
        else { return nil }

        var renderedForAssembly: [NarrationService.RenderedNarrationFile] = []
        for (plan, expectedURL) in zip(orderedPlans, cached.segmentURLs) {
            let matches = renderedSegments.filter { $0.fileURL == expectedURL }
            guard matches.count < 2 else {
                throw Error.duplicateRenderedSegment(segmentIndex: plan.segmentIndex)
            }
            guard let rendered = matches.first else { return nil }
            try validate(rendered, matches: plan)
            renderedForAssembly.append(rendered)
        }

        return try NarrationSegmentAssembly.assemble(
            renderedForAssembly,
            leadOutPadSeconds: leadOutPadSeconds)
    }

    private static func validate(
        _ plannedSegments: [NarrationSegmentPlanner.PlannedSegment],
        firstPlan: NarrationSegmentPlanner.PlannedSegment
    ) throws -> [NarrationSegmentPlanner.PlannedSegment] {
        let orderedPlans = plannedSegments.sorted { $0.segmentIndex < $1.segmentIndex }
        for (expectedIndex, plan) in orderedPlans.enumerated() {
            guard plan.chapterIndex == firstPlan.chapterIndex else {
                throw Error.mixedChapter(
                    expected: firstPlan.chapterIndex,
                    actual: plan.chapterIndex)
            }
            guard plan.chapterDisplayNumber == firstPlan.chapterDisplayNumber else {
                throw Error.mismatchedDisplayNumber(
                    expected: firstPlan.chapterDisplayNumber,
                    actual: plan.chapterDisplayNumber)
            }
            guard plan.segmentIndex == expectedIndex else {
                throw Error.nonContiguousPlan(
                    expected: expectedIndex,
                    actual: plan.segmentIndex)
            }
        }
        return orderedPlans
    }

    private static func validate(
        _ rendered: NarrationService.RenderedNarrationFile,
        matches plan: NarrationSegmentPlanner.PlannedSegment
    ) throws {
        guard rendered.chapterIndex == plan.chapterIndex else {
            throw Error.mismatchedRenderedChapter(
                segmentIndex: plan.segmentIndex,
                expected: plan.chapterIndex,
                actual: rendered.chapterIndex)
        }
        guard rendered.chapterDisplayNumber == plan.chapterDisplayNumber else {
            throw Error.mismatchedRenderedDisplayNumber(
                segmentIndex: plan.segmentIndex,
                expected: plan.chapterDisplayNumber,
                actual: rendered.chapterDisplayNumber)
        }
        guard rendered.segmentIndex == plan.segmentIndex else {
            throw Error.mismatchedRenderedSegmentIndex(
                expected: plan.segmentIndex,
                actual: rendered.segmentIndex)
        }

        let expectedSpokenBlocks = plan.blocks
            .filter { $0.text?.isEmpty == false }
            .map(\.id)
        guard rendered.spokenBlockIDs == expectedSpokenBlocks else {
            throw Error.mismatchedSpokenBlocks(
                segmentIndex: plan.segmentIndex,
                expected: expectedSpokenBlocks,
                actual: rendered.spokenBlockIDs)
        }
    }
}
