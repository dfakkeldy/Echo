// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import os.log

/// User-initiated "listen back" QA for generated narration. For each rendered
/// chapter: re-transcribe the audio, detect heard-vs-source divergences with the
/// deterministic `NarrationQADetector`, label each window with the injected
/// `DivergenceClassifier`, and persist `narration_quality_issue` rows. NOT
/// auto-run after render; the QA pass never mutates the rendered audio.
@MainActor
final class NarrationQAService {
    private let db: DatabaseWriter
    private let classifier: DivergenceClassifier
    private let transcribe: @Sendable (_ fileURL: URL) async -> [TranscribedWord]
    private let logger = Logger(category: "NarrationQA")
    private static let iso = ISO8601DateFormatter()

    init(
        db: DatabaseWriter,
        classifier: DivergenceClassifier,
        transcribe: @escaping @Sendable (_ fileURL: URL) async -> [TranscribedWord] =
            NarrationQAService.whisperTranscribe
    ) {
        self.db = db
        self.classifier = classifier
        self.transcribe = transcribe
    }

    func runQA(
        audiobookID: String,
        chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]
    ) async throws {
        let blockDAO = EPubBlockDAO(db: db)
        let issueDAO = NarrationQualityIssueDAO(db: db)
        let allBlocks = try blockDAO.blocks(for: audiobookID)
        let blocksByID = Dictionary(uniqueKeysWithValues: allBlocks.map { ($0.id, $0) })
        let now = Self.iso.string(from: Date())

        for chapter in chapters {
            // Clear this chapter's prior issues so a re-run converges.
            try issueDAO.deleteAll(for: audiobookID, blockIDs: chapter.spokenBlockIDs)

            let expectedBlocks: [(blockID: String, text: String)] = chapter.spokenBlockIDs
                .compactMap {
                    id in
                    guard let text = blocksByID[id]?.text, !text.isEmpty else { return nil }
                    return (id, TextNormalizer.normalize(text))
                }
            guard !expectedBlocks.isEmpty else { continue }

            let heard = await transcribe(chapter.fileURL)
            guard !heard.isEmpty else {
                logger.notice("QA chapter \(chapter.chapterIndex): no heard words; skipping")
                continue
            }

            let windows = NarrationQADetector.detect(
                expectedBlocks: expectedBlocks, heardWords: heard, audiobookID: audiobookID)

            var records: [NarrationQualityIssueRecord] = []
            for window in windows {
                let c = await classifier.classify(window)
                let fixJSON = Self.encodeFix(c)
                records.append(
                    NarrationQualityIssueRecord(
                        id: UUID().uuidString,
                        audiobookID: audiobookID,
                        sourceBlockID: window.blockID,
                        sourceWordStart: window.expectedWordStart,
                        sourceWordEnd: window.expectedWordEnd,
                        audioStartTime: window.audioStart,
                        audioEndTime: window.audioEnd,
                        expectedText: window.expectedText,
                        heardText: window.heardText,
                        issueType: c.issueType.rawValue,
                        confidence: c.confidence,
                        suggestedFixJSON: fixJSON,
                        status: NarrationQAIssueStatus.open.rawValue,
                        createdAt: now,
                        resolvedAt: nil))
            }
            try issueDAO.insert(records)
            logger.notice("QA chapter \(chapter.chapterIndex): \(records.count) issues")
        }
    }

    private static func encodeFix(_ c: DivergenceClassification) -> String? {
        guard c.suggestedSpokenForm != nil || c.suggestedIPA != nil else { return nil }
        // Encode the shared, typed SuggestedFix (NOT a manual dict) so M5's
        // ContributionPayloadFilter decodes the exact same shape.
        let fix = SuggestedFix(spokenForm: c.suggestedSpokenForm, ipa: c.suggestedIPA)
        return (try? JSONEncoder().encode(fix)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Default transcribe seam: reads the whole file and runs the shared
    /// WhisperKit model (same options the alignment pipeline uses). Returns []
    /// on any failure so QA degrades to "no issues found" rather than crashing.
    static func whisperTranscribe(fileURL: URL) async -> [TranscribedWord] {
        do {
            let duration = try await Self.fileDuration(fileURL)
            let samples = try await AudioSegmentReader.samples(
                from: fileURL, at: 0, duration: duration)
            guard !samples.isEmpty else { return [] }
            let wk = try await WhisperSession.shared.acquire()
            defer { WhisperSession.shared.release() }
            return await AlignmentTranscript.transcribeWords(
                with: wk, samples: samples, captureStart: 0)
        } catch {
            Logger(category: "NarrationQA").error(
                "whisperTranscribe failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func fileDuration(_ fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let d = try await asset.load(.duration)
        return CMTimeGetSeconds(d)
    }
}
