import CoreGraphics
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Stores the state of the PDF view for saving into bookmarks and Anki cards.
// `nonisolated`: a pure `Sendable` value type. Under the iOS target's Swift 6
// MainActor default isolation its synthesized `Equatable`/`Hashable` conformances
// would otherwise be main-actor-isolated, which a `nonisolated` container (e.g.
// the now-`nonisolated` `Bookmark`) cannot use. The `Codable` members are already
// individually `nonisolated`; this covers the synthesized conformances too.
nonisolated struct PDFViewState: Equatable, Hashable, Sendable {
    var pageIndex: Int
    var zoomScale: Double
    var offsetX: Double
    var offsetY: Double
}

// `nonisolated extension`: makes the `Codable` *conformance* itself non-isolated
// (not just the two methods), so GRDB's nonisolated JSON encode/decode path
// (`BookmarkRecord`) can use it under Swift 6 MainActor default isolation.
nonisolated extension PDFViewState: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        zoomScale = try container.decode(Double.self, forKey: .zoomScale)
        offsetX = try container.decode(Double.self, forKey: .offsetX)
        offsetY = try container.decode(Double.self, forKey: .offsetY)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(zoomScale, forKey: .zoomScale)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
    }

    enum CodingKeys: String, CodingKey {
        case pageIndex, zoomScale, offsetX, offsetY
    }
}
