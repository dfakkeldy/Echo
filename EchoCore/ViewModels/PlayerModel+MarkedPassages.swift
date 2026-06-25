#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Mark-later passage capture — the replacement for inline flashcard popups.
extension PlayerModel {
    private static let markedPassagesLogger = Logger(category: "MarkedPassages")

    /// Captures a marked passage at the current playback position.
    /// Default range: [now − 15s, now + 5s]. Fire-and-forget — never blocks playback.
    func markPassageAtCurrentTime() {
        guard let db = databaseService,
              let bookID = folderURL?.absoluteString,
              audioEngine.isItemLoaded else { return }

        let t = audioEngine.currentTime
        guard t.isFinite else { return }

        let start = max(0, t - 15)
        let end = t + 5
        let snippet = resolveSnippet(at: t)

        let dao = MarkedPassageDAO(db: db.writer)
        do {
            _ = try dao.insert(
                audiobookID: bookID,
                mediaTimestamp: start,
                endTimestamp: end,
                transcriptSnippet: snippet,
                note: nil
            )
        } catch {
            Self.markedPassagesLogger.error("Failed to save marked passage: \(error.localizedDescription)")
        }
    }

    private func resolveSnippet(at timestamp: TimeInterval) -> String? {
        // Use the current chapter title as a fallback snippet
        if let ch = state.chapters.first(where: { $0.startSeconds <= timestamp && $0.endSeconds > timestamp }) {
            return "Chapter: \(ch.title ?? "Untitled Chapter")"
        }
        return "Marked at \(formatTimestamp(timestamp))"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        formatHMS(seconds)
    }
}

#endif
