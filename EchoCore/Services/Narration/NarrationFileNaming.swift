import Foundation

/// Single source of truth for narration cache filenames, so the writer
/// (`NarrationService`) and the exporter (`NarrationExportService`) always agree —
/// and so a `file://`-URL `audiobookID` (which contains slashes/colons) becomes a
/// valid filename instead of breaking the write.
enum NarrationFileNaming {
    /// A filesystem-safe token for an audiobook id (which may be a folder-URL string).
    static func safeToken(_ audiobookID: String) -> String {
        let token = String(audiobookID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return token.isEmpty ? "book" : token
    }

    static func chapterFileName(audiobookID: String, chapterIndex: Int, voice: VoiceID) -> String {
        "\(safeToken(audiobookID))-ch\(chapterIndex)-\(voice.rawValue).m4a"
    }

    /// Prefix matching every chapter file for a book (any chapter, any voice).
    static func chapterPrefix(audiobookID: String) -> String {
        "\(safeToken(audiobookID))-ch"
    }
}
