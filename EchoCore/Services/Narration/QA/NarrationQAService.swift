// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import os.log

enum NarrationQAError: Error, Equatable, LocalizedError {
    case transcriptionFailed(chapterIndex: Int, fileURL: URL, underlying: String)
    case noHeardWords(chapterIndex: Int, fileURL: URL)

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let chapterIndex, _, let underlying):
            "Transcription failed for chapter \(chapterIndex): \(underlying)"
        case .noHeardWords(let chapterIndex, _):
            "No spoken words were detected in chapter \(chapterIndex)."
        }
    }
}

/// User-initiated "listen back" QA for generated narration. For each rendered
/// chapter: re-transcribe the audio, detect heard-vs-source divergences with the
/// deterministic `NarrationQADetector`, label each window with the injected
/// `DivergenceClassifier`, and persist `narration_quality_issue` rows. NOT
/// auto-run after render; the QA pass never mutates the rendered audio.
@MainActor
final class NarrationQAService {
    private let db: DatabaseWriter
    private let classifier: DivergenceClassifier
    private let transcribe: @Sendable (_ fileURL: URL) async throws -> [TranscribedWord]
    private let logger = Logger(category: "NarrationQA")
    private static let iso = ISO8601DateFormatter()

    init(
        db: DatabaseWriter,
        classifier: DivergenceClassifier,
        transcribe: @escaping @Sendable (_ fileURL: URL) async throws -> [TranscribedWord] =
            NarrationQAService.whisperTranscribe
    ) {
        self.db = db
        self.classifier = classifier
        self.transcribe = transcribe
    }

    /// Builds the `runQA` chapter list for an initial "Run QA" pass: every chapter
    /// that has rendered narration audio on disk, with its non-hidden block ids as
    /// the spoken set. Pure — callers inject file URL/existence so it is testable
    /// without touching the filesystem. Chapters without a rendered file (or with
    /// only hidden blocks) are skipped.
    static func chaptersToQA(
        blocksByChapter: [Int: [EPubBlockRecord]],
        fileURL: (Int) -> URL,
        fileExists: (URL) -> Bool
    ) -> [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])] {
        blocksByChapter.keys.sorted().compactMap { chapter in
            let spoken = (blocksByChapter[chapter] ?? []).filter { !$0.isHidden }.map(\.id)
            guard !spoken.isEmpty else { return nil }
            let url = fileURL(chapter)
            guard fileExists(url) else { return nil }
            return (chapter, url, spoken)
        }
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
            let expectedBlocks: [(blockID: String, text: String)] = chapter.spokenBlockIDs
                .compactMap {
                    id in
                    guard let text = blocksByID[id]?.text, !text.isEmpty else { return nil }
                    return (id, TextNormalizer.normalize(text))
            }
            guard !expectedBlocks.isEmpty else { continue }

            let heard: [TranscribedWord]
            do {
                heard = try await transcribe(chapter.fileURL)
            } catch let error as NarrationQAError {
                logger.error("QA chapter \(chapter.chapterIndex): \(error.localizedDescription)")
                throw error
            } catch {
                logger.error(
                    "QA chapter \(chapter.chapterIndex): transcription failed: \(error.localizedDescription)"
                )
                throw NarrationQAError.transcriptionFailed(
                    chapterIndex: chapter.chapterIndex,
                    fileURL: chapter.fileURL,
                    underlying: error.localizedDescription)
            }
            guard !heard.isEmpty else {
                logger.error("QA chapter \(chapter.chapterIndex): no heard words")
                throw NarrationQAError.noHeardWords(
                    chapterIndex: chapter.chapterIndex, fileURL: chapter.fileURL)
            }

            let windows = await Self.detectWindows(
                expectedBlocks: expectedBlocks, heardWords: heard)

            var records: [NarrationQualityIssueRecord] = []
            for window in windows {
                let c = await classifier.classify(window)
                let fixJSON = encodeFix(c)
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
            try issueDAO.replaceOpen(for: audiobookID, blockIDs: chapter.spokenBlockIDs, with: records)
            logger.notice("QA chapter \(chapter.chapterIndex): \(records.count) issues")
        }
    }

    private func encodeFix(_ c: DivergenceClassification) -> String? {
        guard c.suggestedSpokenForm != nil || c.suggestedIPA != nil else { return nil }
        // Encode the shared, typed SuggestedFix (NOT a manual dict) so M5's
        // ContributionPayloadFilter decodes the exact same shape.
        let fix = SuggestedFix(spokenForm: c.suggestedSpokenForm, ipa: c.suggestedIPA)
        do {
            let data = try JSONEncoder().encode(fix)
            guard let json = String(data: data, encoding: .utf8) else {
                logger.error("Suggestion fix encode produced non-UTF8 data.")
                return nil
            }
            return json
        } catch {
            logger.error("Suggestion fix encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func detectWindows(
        expectedBlocks: [(blockID: String, text: String)],
        heardWords: [TranscribedWord]
    ) async -> [DivergenceWindow] {
        await Task.detached(priority: .userInitiated) {
            NarrationQADetector.detect(expectedBlocks: expectedBlocks, heardWords: heardWords)
        }.value
    }

    /// Default transcribe seam: reads the whole file and runs the shared
    /// WhisperKit model (same options the alignment pipeline uses). Failures
    /// throw so callers can distinguish them from a genuine no-speech result.
    static func whisperTranscribe(fileURL: URL) async throws -> [TranscribedWord] {
        let duration = try await Self.fileDuration(fileURL)
        let samples = try await AudioSegmentReader.samples(
            from: fileURL, at: 0, duration: duration)
        guard !samples.isEmpty else { return [] }
        let wk = try await WhisperSession.shared.acquire()
        defer { WhisperSession.shared.release() }
        return await AlignmentTranscript.transcribeWords(
            with: wk, samples: samples, captureStart: 0)
    }

    private static func fileDuration(_ fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let d = try await asset.load(.duration)
        return CMTimeGetSeconds(d)
    }
}
