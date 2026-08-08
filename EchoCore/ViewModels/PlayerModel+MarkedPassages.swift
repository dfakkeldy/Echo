#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Mark-later passage capture — the replacement for inline flashcard popups.
extension PlayerModel {
    private static let markedPassagesLogger = Logger(category: "MarkedPassages")

    var canMarkPassage: Bool {
        databaseService != nil
            && bookIdentityURL != nil
            && audioEngine.isItemLoaded
    }

    /// Captures a marked passage at the current playback position.
    /// Default range: [now − 15s, now + 5s]. Fire-and-forget — never blocks playback.
    @discardableResult
    func markPassageAtCurrentTime() -> MarkPassageResult {
        guard let db = databaseService else { return .unavailable }

        let time = audioEngine.currentTime
        return MarkedPassageCapture.capture(
            bookID: bookIdentityURL?.absoluteString,
            isItemLoaded: audioEngine.isItemLoaded,
            time: time,
            snippet: time.isFinite ? resolveSnippet(at: time) : nil,
            persist: { request in
                _ = try MarkedPassageDAO(db: db.writer).insert(
                    audiobookID: request.audiobookID,
                    mediaTimestamp: request.mediaTimestamp,
                    endTimestamp: request.endTimestamp,
                    transcriptSnippet: request.transcriptSnippet,
                    note: nil
                )
            },
            onFailure: { error in
                Self.markedPassagesLogger.error(
                    "Failed to save marked passage: \(error.localizedDescription, privacy: .public)"
                )
            }
        )
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
