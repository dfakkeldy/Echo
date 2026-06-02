import Foundation
import GRDB

/// A parsed EPUB block — heading, paragraph, sentence, or image — extracted
/// from XHTML spine items and stored in structural reading order.
struct EPubBlockRecord: Identifiable, Equatable, Hashable, Sendable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var spineHref: String
    var spineIndex: Int
    var blockIndex: Int
    var sequenceIndex: Int
    var blockKind: String
    var text: String?
    var htmlContent: String?
    var cardColor: String?
    var imagePath: String?
    var chapterIndex: Int?
    var isHidden: Bool
    var hiddenReason: String?
    var wordCount: Int?
    var markers: String?        // JSON-encoded [SyncMarker]
    var textFormats: String?    // JSON-encoded [TextFormat]
    var createdAt: String?
    var modifiedAt: String?

    static let databaseTableName = "epub_block"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case spineHref = "spine_href"
        case spineIndex = "spine_index"
        case blockIndex = "block_index"
        case sequenceIndex = "sequence_index"
        case blockKind = "block_kind"
        case text
        case htmlContent = "html_content"
        case cardColor = "card_color"
        case imagePath = "image_path"
        case chapterIndex = "chapter_index"
        case isHidden = "is_hidden"
        case hiddenReason = "hidden_reason"
        case wordCount = "word_count"
        case markers
        case textFormats = "text_formats"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

extension EPubBlockRecord {
    /// Block kind constants used in the `block_kind` column.
    enum Kind: String {
        case heading
        case paragraph
        case sentence
        case image
    }

    /// Encode markers to JSON for database storage.
    /// Returns nil for empty arrays to keep storage clean.
    static func encodeMarkers(_ markers: [SyncMarker]) -> String? {
        guard !markers.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(markers) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Encode text formats to JSON for database storage.
    /// Returns nil for empty arrays to keep storage clean.
    static func encodeFormats(_ formats: [TextFormat]) -> String? {
        guard !formats.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(formats) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode markers from the JSON column. Returns empty array on failure or nil.
    var decodedMarkers: [SyncMarker] {
        guard let markers, let data = markers.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SyncMarker].self, from: data)) ?? []
    }

    /// Decode text formats from the JSON column. Returns empty array on failure or nil.
    var decodedFormats: [TextFormat] {
        guard let textFormats, let data = textFormats.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TextFormat].self, from: data)) ?? []
    }
}
