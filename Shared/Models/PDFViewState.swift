import Foundation
import CoreGraphics

/// Stores the state of the PDF view for saving into bookmarks and Anki cards.
struct PDFViewState: Equatable, Hashable, Sendable {
    var pageIndex: Int
    var zoomScale: Double
    var offsetX: Double
    var offsetY: Double
}

extension PDFViewState: Codable {
    nonisolated init(from decoder: Decoder) throws {
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