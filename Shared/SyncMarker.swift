// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SyncMarker: Codable, Equatable, Sendable {
    public let type: MarkerType
    public let payload: String
    public let epubCharOffset: Int

    public init(type: MarkerType, payload: String, epubCharOffset: Int) {
        self.type = type
        self.payload = payload
        self.epubCharOffset = epubCharOffset
    }
}

public enum MarkerType: String, Codable, Equatable, Sendable {
    case chapterStart
    case image
    case hyperlink
    case blockquote
    case list
    case table
    case footnote
    case horizontalRule
    case emphasis
}
