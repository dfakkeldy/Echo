// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Builds and validates block-level alignment sidecars for audio that was not
/// synthesized by Echo's native narration pipeline. The timestamps are estimated,
/// so callers should keep confidence below native synthesis.
nonisolated enum EstimatedAlignmentSidecar {
    struct ChapterTiming: Equatable, Sendable {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval

        init(index: Int, start: TimeInterval, end: TimeInterval) {
            self.index = index
            self.start = start
            self.end = end
        }
    }

    enum BuildError: Error, Equatable, LocalizedError {
        case noReadableBlocks
        case noChapterTimings
        case chapterCountMismatch(spineGroups: Int, chapterTimings: Int)

        var errorDescription: String? {
            switch self {
            case .noReadableBlocks:
                return "No readable EPUB/PDF text blocks were found."
            case .noChapterTimings:
                return "No usable audio chapter timings were found."
            case .chapterCountMismatch(let spineGroups, let chapterTimings):
                return "Cannot estimate sidecar: \(spineGroups) source spine groups for \(chapterTimings) audio chapters."
            }
        }
    }

    static func build(
        blocks: [EPubBlockRecord],
        chapterTimings: [ChapterTiming],
        confidence: Double = 0.5
    ) throws -> [AlignmentSidecar.Anchor] {
        let readable = readableBlocks(from: blocks)
        guard !readable.isEmpty else { throw BuildError.noReadableBlocks }

        let timings = chapterTimings
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !timings.isEmpty else { throw BuildError.noChapterTimings }

        let groups = Dictionary(grouping: readable, by: \.spineIndex)
            .keys
            .sorted()
            .map { spine in
                readable
                    .filter { $0.spineIndex == spine }
                    .sorted { $0.sequenceIndex < $1.sequenceIndex }
            }
            .filter { !$0.isEmpty }

        guard groups.count == timings.count else {
            throw BuildError.chapterCountMismatch(
                spineGroups: groups.count,
                chapterTimings: timings.count
            )
        }

        return zip(groups, timings).flatMap { group, timing in
            anchors(for: group, in: timing, confidence: confidence)
        }
    }

    static func readableBlocks(from blocks: [EPubBlockRecord]) -> [EPubBlockRecord] {
        blocks
            .filter { block in
                guard !block.isHidden,
                    EPubBlockRecord.Kind(rawValue: block.blockKind) != .image,
                    let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return false }
                return true
            }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
    }

    private static func anchors(
        for blocks: [EPubBlockRecord],
        in timing: ChapterTiming,
        confidence: Double
    ) -> [AlignmentSidecar.Anchor] {
        let duration = timing.end - timing.start
        let weights = blocks.map(blockWeight)
        let totalWeight = max(1, weights.reduce(0, +))
        var cursor = timing.start
        var anchors: [AlignmentSidecar.Anchor] = []
        anchors.reserveCapacity(blocks.count)

        for (block, weight) in zip(blocks, weights) {
            anchors.append(
                AlignmentSidecar.Anchor(
                    blockId: AlignmentSidecar.portableSuffix(of: block.id),
                    timestamp: cursor,
                    confidence: confidence
                )
            )
            cursor += duration * (Double(max(1, weight)) / Double(totalWeight))
        }
        return anchors
    }

    private static func blockWeight(_ block: EPubBlockRecord) -> Int {
        if let wordCount = block.wordCount, wordCount > 0 {
            return wordCount
        }
        return max(1, block.text?.split(whereSeparator: \.isWhitespace).count ?? 1)
    }
}

nonisolated enum AlignmentSidecarVerifier {
    struct Report: Equatable, Sendable {
        let anchorCount: Int
        let chapterCount: Int
    }

    enum Issue: Equatable, Sendable, CustomStringConvertible {
        case emptySidecar
        case noChapterTimings
        case invalidAudioDuration(TimeInterval)
        case unresolvedBlockID(String)
        case timestampDecreased(blockID: String, timestamp: TimeInterval)
        case timestampOutOfRange(blockID: String, timestamp: TimeInterval)
        case chapterWithoutAnchors(index: Int)

        var description: String {
            switch self {
            case .emptySidecar:
                return "sidecar has no anchors"
            case .noChapterTimings:
                return "audio has no usable chapter timings"
            case .invalidAudioDuration(let duration):
                return "audio duration is invalid: \(duration)"
            case .unresolvedBlockID(let blockID):
                return "sidecar block id does not resolve: \(blockID)"
            case .timestampDecreased(let blockID, let timestamp):
                return "timestamp decreased at \(blockID): \(timestamp)"
            case .timestampOutOfRange(let blockID, let timestamp):
                return "timestamp is outside audio duration at \(blockID): \(timestamp)"
            case .chapterWithoutAnchors(let index):
                return "audio chapter \(index) has no resolved sidecar anchors"
            }
        }
    }

    struct VerificationError: Error, Equatable, LocalizedError {
        let issues: [Issue]

        var errorDescription: String? {
            issues.map(\.description).joined(separator: "\n")
        }
    }

    static func verify(
        anchors: [AlignmentSidecar.Anchor],
        blocks: [EPubBlockRecord],
        chapterTimings: [EstimatedAlignmentSidecar.ChapterTiming],
        audioDuration: TimeInterval
    ) throws -> Report {
        var issues: [Issue] = []

        if anchors.isEmpty {
            issues.append(.emptySidecar)
        }

        let timings = chapterTimings
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        if timings.isEmpty {
            issues.append(.noChapterTimings)
        }
        if !audioDuration.isFinite || audioDuration <= 0 {
            issues.append(.invalidAudioDuration(audioDuration))
        }

        let resolvableSuffixes = Set(
            EstimatedAlignmentSidecar
                .readableBlocks(from: blocks)
                .map { AlignmentSidecar.portableSuffix(of: $0.id) }
        )
        var previousTimestamp: TimeInterval?
        var resolvedAnchors: [AlignmentSidecar.Anchor] = []

        for anchor in anchors {
            let suffix = AlignmentSidecar.portableSuffix(of: anchor.blockId)
            let resolves = resolvableSuffixes.contains(suffix)
            if !resolves {
                issues.append(.unresolvedBlockID(anchor.blockId))
            }
            if let previousTimestamp, anchor.timestamp < previousTimestamp {
                issues.append(
                    .timestampDecreased(blockID: anchor.blockId, timestamp: anchor.timestamp)
                )
            }
            previousTimestamp = anchor.timestamp

            if !anchor.timestamp.isFinite || anchor.timestamp < 0 || anchor.timestamp > audioDuration {
                issues.append(
                    .timestampOutOfRange(blockID: anchor.blockId, timestamp: anchor.timestamp)
                )
            } else if resolves {
                resolvedAnchors.append(anchor)
            }
        }

        for timing in timings
        where !resolvedAnchors.contains(where: { anchor in
            if timing.index == timings.last?.index {
                return anchor.timestamp >= timing.start && anchor.timestamp <= timing.end
            }
            return anchor.timestamp >= timing.start && anchor.timestamp < timing.end
        }) {
            issues.append(.chapterWithoutAnchors(index: timing.index))
        }

        guard issues.isEmpty else {
            throw VerificationError(issues: issues)
        }
        return Report(anchorCount: anchors.count, chapterCount: timings.count)
    }
}
