import Foundation
import CoreGraphics

/// Stores the state of the PDF view for saving into bookmarks and Anki cards.
struct PDFViewState: Codable, Equatable, Hashable {
    var pageIndex: Int
    var zoomScale: Double
    var offsetX: Double
    var offsetY: Double
}