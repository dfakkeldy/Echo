import Foundation

/// Structural marker injected into a transcription segment during EPUB alignment.
/// Mirrors `OrbitEPUBAligner.SyncMarker` so the iOS app can decode enhanced transcripts
/// without depending on the CLI tool's Swift Package module.
public struct SyncMarker: Codable, Equatable {
    public let type: MarkerType
    public let payload: String
    public let epubCharOffset: Int

    public init(type: MarkerType, payload: String, epubCharOffset: Int) {
        self.type = type
        self.payload = payload
        self.epubCharOffset = epubCharOffset
    }
}

public enum MarkerType: String, Codable, Equatable {
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
