// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Scope for a pronunciation fix: a specific book or the global dictionary.
enum FixScope: Equatable {
    case book(String)
    case global
}

/// Thrown when an issue carries no actionable pronunciation suggestion.
enum NarrationRepairError: Error, Equatable, LocalizedError {
    case noUsableFix
    case sourceChapterUnavailable

    var errorDescription: String? {
        switch self {
        case .noUsableFix:
            "This issue has no usable pronunciation fix."
        case .sourceChapterUnavailable:
            "The source chapter for this issue could not be found."
        }
    }
}

/// Turns an accepted narration-QA fix into a pronunciation override, regenerates
/// the affected chapter, re-runs QA on it, and resolves the issue. Pure EchoCore
/// (no UIKit / no `PlayerModel`) so it bundles into iOS, macOS, and echo-cli
/// unchanged. Concrete-type + constructor injection (no protocol): there is one
/// implementation.
@MainActor
final class PronunciationRepairService {
    private let store: PronunciationOverrideStore
    private let issueDAO: NarrationQualityIssueDAO
    private let db: DatabaseWriter
    private let cacheDirectory: URL
    private let voice: VoiceID
    /// Re-render exactly the given chapter index with the live override map.
    private let renderChapter: (Int) async throws -> Void
    /// Re-run narration QA over exactly the given chapter index.
    private let reRunQA: (Int) async throws -> Void
    private let logger = Logger(category: "NarrationRepair")

    init(
        store: PronunciationOverrideStore,
        issueDAO: NarrationQualityIssueDAO,
        db: DatabaseWriter,
        cacheDirectory: URL,
        voice: VoiceID,
        renderChapter: @escaping (Int) async throws -> Void,
        reRunQA: @escaping (Int) async throws -> Void
    ) {
        self.store = store
        self.issueDAO = issueDAO
        self.db = db
        self.cacheDirectory = cacheDirectory
        self.voice = voice
        self.renderChapter = renderChapter
        self.reRunQA = reRunQA
    }

    /// Resolve the `epub_block.chapter_index` for a block id. Used to scope
    /// regeneration to the single chapter that contains a flagged issue.
    static func chapterIndex(
        forBlockID blockID: String, audiobookID: String, db: DatabaseWriter
    ) throws -> Int? {
        try db.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT chapter_index FROM epub_block
                    WHERE id = ? AND audiobook_id = ?
                    """,
                arguments: [blockID, audiobookID])
        }
    }

    /// Apply an accepted pronunciation fix end to end: write the override for the
    /// chosen scope, drop the affected chapter's cached audio + sibling open issues,
    /// re-render that one chapter (which now reads the new override), re-run QA on
    /// it, and mark the original issue resolved. Throws if the issue has no usable
    /// suggested fix.
    func applyFix(issue: NarrationQualityIssueRecord, scope: FixScope) async throws {
        // 1. Decode the suggested fix -> (word, ipa).
        let decoded: SuggestedFix
        guard let json = issue.suggestedFixJSON,
            let data = json.data(using: .utf8),
            let fix = try? JSONDecoder().decode(SuggestedFix.self, from: data),
            let ipa = fix.ipa, !ipa.isEmpty
        else {
            throw NarrationRepairError.noUsableFix
        }
        decoded = fix
        // Prefer the model's suggested spoken form for the override key; fall back to
        // the expected source text (whole-word matched by PronunciationOverrides).
        let word =
            (decoded.spokenForm?.isEmpty == false
            ? decoded.spokenForm! : issue.expectedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw NarrationRepairError.noUsableFix }

        // 2. Write the override in the chosen scope.
        switch scope {
        case .book(let bookID):
            try store.set(word: word, ipa: ipa, forBookID: bookID)
        case .global:
            try store.set(word: word, ipa: ipa)
        }

        // 3. Resolve the chapter to regenerate.
        guard let blockID = issue.sourceBlockID else {
            logger.error(
                "Override written for issue \(issue.id), but the issue has no source block.")
            throw NarrationRepairError.sourceChapterUnavailable
        }
        guard let chapterIndex = try Self.chapterIndex(
            forBlockID: blockID, audiobookID: issue.audiobookID, db: db)
        else {
            logger.error(
                "Override written for issue \(issue.id), but source block \(blockID) could not be resolved."
            )
            throw NarrationRepairError.sourceChapterUnavailable
        }

        // 4. Clear stale cached audio.
        let cachedFile = cacheDirectory.appendingPathComponent(
            NarrationFileNaming.chapterFileName(
                audiobookID: issue.audiobookID, chapterIndex: chapterIndex, voice: voice))
        try? FileManager.default.removeItem(at: cachedFile)
        logger.notice("Cleared cached audio for chapter \(chapterIndex)")

        // 5. Re-render the chapter (reads the new override via NarrationService's
        //    pronunciationOverrides closure) then re-run QA over it.
        try await renderChapter(chapterIndex)
        try await reRunQA(chapterIndex)

        // 6. Only after render + re-QA both succeed, save the accepted issue as
        //    resolved audit history. The re-QA pass may have deleted the original
        //    open row, so this helper upserts the resolved copy.
        let resolvedAt = ISO8601DateFormatter().string(from: Date())
        try issueDAO.saveResolvedAudit(issue, resolvedAt: resolvedAt)
    }
}
