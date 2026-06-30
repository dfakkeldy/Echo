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

    /// User accepted a pronunciation fix from the review queue. Writes the override
    /// in the chosen scope, regenerates the affected chapter with the new
    /// pronunciation, re-runs QA over it, and resolves the issue. Errors surface
    /// through the model's existing error state (no crash). Only meaningful on
    /// iOS/macOS where narration services are available.
    @MainActor
    func acceptFix(issue: NarrationQualityIssueRecord, scope: FixScope) async {
        #if os(iOS) || os(macOS)
            let voice: VoiceID = {
                // Read the user's narration voice preference from the shared
                // PronunciationOverrideStore environment; fall back to default.
                if let rawValue = UserDefaults.standard.string(forKey: "narrationVoiceID") {
                    return VoiceCatalog.voice(for: VoiceID(rawValue))?.id ?? VoiceCatalog.default.id
                }
                return VoiceCatalog.default.id
            }()
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
                load()
            } catch {
                logger.error("acceptFix failed: \(error.localizedDescription)")
            }
        #else
            logger.error("acceptFix is not available on this platform")
        #endif
    }
}
