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
        let snippet = resolveSnippet(at: t, bookID: bookID, db: db)

        let dao = MarkedPassageDAO(db: db.writer)
        do {
            try dao.insert(
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

    private func resolveSnippet(at timestamp: TimeInterval, bookID: String, db: DatabaseService) -> String? {
        // Use the current chapter title as a fallback snippet
        if let ch = state.chapters.first(where: { $0.startSeconds <= timestamp && $0.endSeconds > timestamp }) {
            return "Chapter: \(ch.title)"
        }
        return "Marked at \(formatTimestamp(timestamp))"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
