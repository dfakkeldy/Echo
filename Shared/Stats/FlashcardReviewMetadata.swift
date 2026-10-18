// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct FlashcardReviewMetadata: Codable, Equatable, Sendable {
    let cardId: String?
    let grade: Int
    let intervalDays: Int?
    /// True when the grade was auto-fired by the checkpoint timeout, not a
    /// deliberate tap. Optional so older rows decode unchanged and tap grades
    /// omit the key entirely.
    let auto: Bool?
    /// True when this row records a retention-neutral skip. Skip rows use their
    /// own event type and keep `grade` at 0.
    let skipped: Bool?

    init(
        cardID: String,
        grade: Int,
        intervalDays: Int?,
        auto: Bool? = nil,
        skipped: Bool? = nil
    ) {
        self.cardId = cardID
        self.grade = grade
        self.intervalDays = intervalDays
        self.auto = auto
        self.skipped = skipped
    }

    init(card: Flashcard, grade: Int, auto: Bool? = nil) {
        self.init(cardID: card.id, grade: grade, intervalDays: card.intervalDays, auto: auto)
    }

    nonisolated func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func decode(_ jsonString: String?) -> FlashcardReviewMetadata? {
        guard let jsonString, let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(FlashcardReviewMetadata.self, from: data)
    }
}
