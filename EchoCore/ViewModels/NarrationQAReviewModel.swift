// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

/// Drives the per-book narration-QA review screen: loads open issues and applies
/// ignore/resolve status changes (override + regenerate actions land in M4). Pure
/// Foundation (no UIKit), so it bundles into every target without exclusion.
@MainActor
@Observable
final class NarrationQAReviewModel {
    var issues: [NarrationQualityIssueRecord] = []
    /// User-facing message for the most recent failure (transcription error,
    /// no rendered audio, repair failure). `nil` when the last action succeeded.
    var lastError: String?

    private let db: DatabaseWriter
    private let audiobookID: String
    private let logger = Logger(category: "NarrationQAReview")
    private static let iso = ISO8601DateFormatter()

    init(db: DatabaseWriter, audiobookID: String) {
        self.db = db
        self.audiobookID = audiobookID
    }

    func load() {
        do {
            issues = try NarrationQualityIssueDAO(db: db)
                .issues(for: audiobookID, status: NarrationQAIssueStatus.open.rawValue)
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
            issues = []
        }
    }

    /// Testable core of the initial "Run QA" pass: runs the injected QA work over
    /// the pre-resolved rendered chapters, then reloads the open queue. Surfaces a
    /// message via `lastError` when there is nothing rendered to check or the pass
    /// throws — so the user never sees an empty queue that silently did nothing.
    func runFullQA(
        chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])],
        run: (_ chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])])
            async throws -> Void
    ) async {
        guard !chapters.isEmpty else {
            lastError =
                "No narrated audio found to check. Generate narration for this book first."
            return
        }
        do {
            try await run(chapters)
            lastError = nil
            load()
        } catch {
            logger.error("runFullQA failed: \(error.localizedDescription)")
            lastError = "Narration QA couldn't finish: \(error.localizedDescription)"
        }
    }

    func ignore(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .ignored, resolvedAt: nil)
    }

    func markResolved(_ issue: NarrationQualityIssueRecord) {
        update(issue, status: .resolved, resolvedAt: Self.iso.string(from: Date()))
    }

    private func update(
        _ issue: NarrationQualityIssueRecord, status: NarrationQAIssueStatus, resolvedAt: String?
    ) {
        do {
            try NarrationQualityIssueDAO(db: db)
                .updateStatus(id: issue.id, status: status.rawValue, resolvedAt: resolvedAt)
            issues.removeAll { $0.id == issue.id }
        } catch {
            logger.error("update status failed: \(error.localizedDescription)")
        }
    }

    #if os(iOS) || os(macOS)
        /// The user's narration-voice preference, or the catalog default.
        private static func resolveVoice() -> VoiceID {
            if let rawValue = UserDefaults.standard.string(forKey: "narrationVoiceID") {
                return VoiceCatalog.voice(for: VoiceID(rawValue))?.id ?? VoiceCatalog.default.id
            }
            return VoiceCatalog.default.id
        }

        /// Production "Run QA / Listen Back" entry point: discover every chapter that
        /// has rendered narration audio, run the deterministic QA pass over them, and
        /// reload the queue. The book must already be narrated; otherwise `lastError`
        /// explains there is nothing to check (instead of a silent empty queue).
        @MainActor
        func runFullQA() async {
            let voice = Self.resolveVoice()
            let chapters: [(chapterIndex: Int, fileURL: URL, spokenBlockIDs: [String])]
            do {
                let blocksByChapter = try EPubBlockDAO(db: db).blocksByChapter(for: audiobookID)
                let dir = NarrationCache.directory()
                chapters = NarrationQAService.chaptersToQA(
                    blocksByChapter: blocksByChapter,
                    fileURL: {
                        dir.appendingPathComponent(
                            NarrationFileNaming.chapterFileName(
                                audiobookID: audiobookID, chapterIndex: $0, voice: voice))
                    },
                    fileExists: { FileManager.default.fileExists(atPath: $0.path) })
            } catch {
                logger.error("runFullQA chapter scan failed: \(error.localizedDescription)")
                lastError = "Couldn't read this book's chapters: \(error.localizedDescription)"
                return
            }
            await runFullQA(chapters: chapters) { [db, audiobookID] chapters in
                let qa = NarrationQAService(
                    db: db, classifier: DeterministicDivergenceClassifier())
                try await qa.runQA(audiobookID: audiobookID, chapters: chapters)
            }
        }
    #endif

    /// User accepted a pronunciation fix from the review queue. Writes the override
    /// in the chosen scope, regenerates the affected chapter with the new
    /// pronunciation, re-runs QA over it, and resolves the issue. Errors surface
    /// through the model's existing error state (no crash). Only meaningful on
    /// iOS/macOS where narration services are available.
    @MainActor
    func acceptFix(issue: NarrationQualityIssueRecord, scope: FixScope) async {
        #if os(iOS) || os(macOS)
            let voice = Self.resolveVoice()
            let blockDAO = EPubBlockDAO(db: db)

            let narration = NarrationService(
                db: db, audiobookID: audiobookID,
                tts: NarrationEngineFactory.make(),
                audioWriter: AVFoundationAudioWriter(),
                cacheDirectory: NarrationCache.directory(),
                state: NarrationState(),
                pronunciationOverrides: { [audiobookID] in
                    PronunciationOverrideStore.shared.overrides(forBookID: audiobookID)
                })

            let qa = NarrationQAService(
                db: db,
                classifier: DeterministicDivergenceClassifier())

            let repair = PronunciationRepairService(
                store: PronunciationOverrideStore.shared,
                issueDAO: NarrationQualityIssueDAO(db: db),
                db: db,
                cacheDirectory: NarrationCache.directory(),
                voice: voice,
                renderChapter: { [audiobookID] chapterIndex in
                    let blocks = try blockDAO.blocks(for: audiobookID, chapterIndex: chapterIndex)
                    try await narration.renderChapter(
                        chapterIndex: chapterIndex, blocks: blocks, voice: voice)
                },
                reRunQA: { [audiobookID] chapterIndex in
                    let blocks = try blockDAO.blocks(for: audiobookID, chapterIndex: chapterIndex)
                    let fileURL = NarrationCache.directory().appendingPathComponent(
                        NarrationFileNaming.chapterFileName(
                            audiobookID: audiobookID, chapterIndex: chapterIndex, voice: voice))
                    try await qa.runQA(
                        audiobookID: audiobookID,
                        chapters: [
                            (
                                chapterIndex: chapterIndex, fileURL: fileURL,
                                spokenBlockIDs: blocks.map(\.id)
                            )
                        ])
                })
            do {
                try await repair.applyFix(issue: issue, scope: scope)
                lastError = nil
                load()
            } catch NarrationRepairError.noUsableFix {
                lastError =
                    "This issue has no pronunciation fix to apply. Add an IPA spelling first."
            } catch {
                logger.error("acceptFix failed: \(error.localizedDescription)")
                lastError = "Couldn't apply the fix: \(error.localizedDescription)"
            }
        #else
            logger.error("acceptFix is not available on this platform")
        #endif
    }
}
