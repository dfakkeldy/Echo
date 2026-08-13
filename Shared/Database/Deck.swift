// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// GRDB record for the `deck` table.
struct Deck: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: String
    var name: String
    var source: String
    var ankiDeckID: Int?
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "deck"

    enum CodingKeys: String, CodingKey {
        case id, name, source
        case ankiDeckID = "anki_deck_id"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
