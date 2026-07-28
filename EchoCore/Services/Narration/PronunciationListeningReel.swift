// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation

nonisolated enum PronunciationArtifactIntegrity {
    enum IntegrityError: LocalizedError, Sendable {
        case missingOrNonRegular(URL)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .missingOrNonRegular(let url):
                return "Pronunciation artifact is missing or not a regular file: \(url.path)"
            case .mismatch(let detail):
                return "Pronunciation artifact integrity mismatch: \(detail)"
            }
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw IntegrityError.missingOrNonRegular(url)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0)
            }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Result of the pronunciation-review phase of a headless narration run.
nonisolated enum PronunciationReviewOutcome: Equatable, Sendable {
    /// The narration is still partial, so no final-audiobook review can exist yet.
    case pending
    /// The caller explicitly opted out and any stale siblings were removed.
    case disabled
    /// A valid audit exists, but there were no safely timed samples for a reel.
    case auditOnly(auditURL: URL)
    /// Both the audit receipt and bounded listening reel were generated.
    case generated(auditURL: URL, reelURL: URL)
}

/// Immutable input to the post-export review phase. The runner snapshots the
/// MainActor-owned watch vocabulary before constructing this portable value.
nonisolated struct PronunciationReviewRequest: Equatable, Sendable {
    let audiobookURL: URL
    let auditURL: URL
    let reelURL: URL
    let renderVersion: Int
    let voice: VoiceID
    let chapterVoices: [Int: VoiceID]
    let captureCoverage: PronunciationAuditCoverage
    let legacyChapterIndexes: [Int]
    let decisions: [PronunciationAuditDecision]
    let diagnostics: [PronunciationAuditDiagnostic]
    let watchWords: [String]

    init(
        audiobookURL: URL,
        auditURL: URL,
        reelURL: URL,
        renderVersion: Int,
        voice: VoiceID,
        chapterVoices: [Int: VoiceID] = [:],
        captureCoverage: PronunciationAuditCoverage,
        legacyChapterIndexes: [Int],
        decisions: [PronunciationAuditDecision],
        diagnostics: [PronunciationAuditDiagnostic],
        watchWords: [String]
    ) {
        self.audiobookURL = audiobookURL
        self.auditURL = auditURL
        self.reelURL = reelURL
        self.renderVersion = renderVersion
        self.voice = voice
        self.chapterVoices = chapterVoices
        self.captureCoverage = captureCoverage
        self.legacyChapterIndexes = legacyChapterIndexes
        self.decisions = decisions
        self.diagnostics = diagnostics
        self.watchWords = watchWords
    }
}

/// Pure conversion from timed audit decisions to slices of the final audiobook.
/// `AudioExportService` consumes these items and stamps one chapter per sample.
nonisolated enum PronunciationListeningReel {
    static let maximumSampleCount = 16
    static let exactTimingEdgePadding: TimeInterval = 0.25

    private struct SampleKey: Hashable {
        let normalizedWord: String
        let selectedIPA: String
        let ruleID: String
    }

    static func exportItems(
        decisions: [PronunciationAuditDecision],
        audiobookURL: URL,
        sourceDuration: CMTime
    ) -> [ExportItem] {
        let sourceDurationSeconds = sourceDuration.seconds
        guard sourceDurationSeconds.isFinite, sourceDurationSeconds > 0 else { return [] }

        let preferredTimescale: CMTimeScale = max(sourceDuration.timescale, 600_000)
        var seen: Set<SampleKey> = []
        var items: [ExportItem] = []

        for decision in decisions {
            guard items.count < maximumSampleCount else { break }
            let key = SampleKey(
                normalizedWord: decision.normalizedWord,
                selectedIPA: decision.selectedIPA,
                ruleID: decision.ruleID)
            guard !seen.contains(key),
                let range = decision.bookRelativeAudioRange,
                let precision = decision.timingPrecision,
                range.start.isFinite,
                range.end.isFinite,
                range.end > range.start
            else {
                continue
            }

            let proposedStart: TimeInterval
            let proposedEnd: TimeInterval
            switch precision {
            case .exactSynthesisWord:
                proposedStart = range.start - exactTimingEdgePadding
                proposedEnd = range.end + exactTimingEdgePadding
            case .blockAnchorFallback:
                proposedStart = range.start
                proposedEnd = range.end
            }

            let clampedStartSeconds = min(max(proposedStart, 0), sourceDurationSeconds)
            let clampedEndSeconds = min(max(proposedEnd, 0), sourceDurationSeconds)
            guard clampedStartSeconds.isFinite,
                clampedEndSeconds.isFinite,
                clampedEndSeconds > clampedStartSeconds
            else {
                continue
            }

            var start = CMTime(
                seconds: clampedStartSeconds,
                preferredTimescale: preferredTimescale)
            var end = CMTime(
                seconds: clampedEndSeconds,
                preferredTimescale: preferredTimescale)
            if CMTimeCompare(start, .zero) < 0 { start = .zero }
            if CMTimeCompare(end, sourceDuration) > 0 { end = sourceDuration }
            guard start.isNumeric, end.isNumeric, CMTimeCompare(end, start) > 0 else {
                continue
            }

            // Invalid earlier occurrences must not shadow a later valid sample.
            seen.insert(key)
            let sampleNumber = items.count + 1
            items.append(
                ExportItem(
                    title:
                        "\(sampleNumber). \(decision.normalizedWord) — \(decision.ruleID) — /\(decision.selectedIPA)/",
                    url: audiobookURL,
                    timeRange: CMTimeRange(start: start, end: end)))
        }

        return items
    }
}

/// Production post-export generator. The reel is exported to a unique sibling
/// ending in `.m4b` because `ChapterMarkerWriter` mutates its destination; only a
/// completed reel is atomically promoted, and the manifest is always written last.
@MainActor enum PronunciationReviewArtifactGenerator {
    static func generate(
        _ request: PronunciationReviewRequest,
        fileManager: FileManager = .default
    ) async throws -> PronunciationReviewOutcome {
        try removeIfPresent(request.auditURL, fileManager: fileManager)
        try removeIfPresent(request.reelURL, fileManager: fileManager)
        do {
            return try await generateClean(request, fileManager: fileManager)
        } catch {
            try? removeIfPresent(request.auditURL, fileManager: fileManager)
            try? removeIfPresent(request.reelURL, fileManager: fileManager)
            throw error
        }
    }

    private static func generateClean(
        _ request: PronunciationReviewRequest,
        fileManager: FileManager
    ) async throws -> PronunciationReviewOutcome {
        let audiobookSHA256 = try PronunciationArtifactIntegrity.sha256Hex(of: request.audiobookURL)
        let items: [ExportItem]
        if request.decisions.isEmpty {
            items = []
        } else {
            let duration = try await AVURLAsset(url: request.audiobookURL).load(.duration)
            items = PronunciationListeningReel.exportItems(
                decisions: request.decisions,
                audiobookURL: request.audiobookURL,
                sourceDuration: duration)
        }

        if items.isEmpty {
            let manifest = makeManifest(
                request: request,
                audiobookSHA256: audiobookSHA256,
                reelURL: nil,
                listeningReelSHA256: nil)
            try manifest.write(to: request.auditURL, fileManager: fileManager)
            try manifest.validateArtifacts(
                audiobookURL: request.audiobookURL,
                reelURL: nil)
            return .auditOnly(auditURL: request.auditURL)
        }

        let parent = request.reelURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryReelURL = parent.appendingPathComponent(
            ".\(request.reelURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).m4b")
        defer { try? fileManager.removeItem(at: temporaryReelURL) }

        try await AudioExportService().exportM4B(
            items: items,
            outputURL: temporaryReelURL,
            metadata: ExportMetadata(
                title: "Pronunciation Review — \(request.audiobookURL.deletingPathExtension().lastPathComponent)",
                author: "Echo",
                coverArt: nil))
        try promote(
            temporaryReelURL,
            to: request.reelURL,
            fileManager: fileManager)

        let finalAudiobookSHA256 = try PronunciationArtifactIntegrity.sha256Hex(
            of: request.audiobookURL)
        guard finalAudiobookSHA256 == audiobookSHA256 else {
            throw PronunciationArtifactIntegrity.IntegrityError.mismatch(
                "audiobook changed while generating its listening reel")
        }
        let listeningReelSHA256 = try PronunciationArtifactIntegrity.sha256Hex(of: request.reelURL)
        let manifest = makeManifest(
            request: request,
            audiobookSHA256: finalAudiobookSHA256,
            reelURL: request.reelURL,
            listeningReelSHA256: listeningReelSHA256)
        try manifest.write(to: request.auditURL, fileManager: fileManager)
        try manifest.validateArtifacts(
            audiobookURL: request.audiobookURL,
            reelURL: request.reelURL)
        return .generated(auditURL: request.auditURL, reelURL: request.reelURL)
    }

    private static func makeManifest(
        request: PronunciationReviewRequest,
        audiobookSHA256: String,
        reelURL: URL?,
        listeningReelSHA256: String?
    ) -> PronunciationAuditManifest {
        PronunciationAuditManifest.make(
            renderVersion: request.renderVersion,
            voice: request.voice,
            chapterVoices: request.chapterVoices,
            captureCoverage: request.captureCoverage,
            legacyChapterIndexes: request.legacyChapterIndexes,
            audiobookURL: request.audiobookURL,
            reelURL: reelURL,
            audiobookSHA256: audiobookSHA256,
            listeningReelSHA256: listeningReelSHA256,
            watchWords: request.watchWords,
            decisions: request.decisions,
            diagnostics: request.diagnostics)
    }

    private static func promote(
        _ temporaryURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
