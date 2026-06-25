// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct FlashcardReviewMetadata: Codable, Equatable, Sendable {
    let cardId: String?
    let grade: Int
    let intervalDays: Int?

    init(cardID: String, grade: Int, intervalDays: Int?) {
        self.cardId = cardID
        self.grade = grade
        self.intervalDays = intervalDays
    }

    init(card: Flashcard, grade: Int) {
        self.init(cardID: card.id, grade: grade, intervalDays: card.intervalDays)
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
