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

    /// Recovers the chapter index from a name produced by `chapterFileName`,
    /// or `nil` if the name isn't a narration chapter file. Used to resume at the
    /// last-played chapter on reopen.
    static func chapterIndex(fromFileName fileName: String) -> Int? {
        guard let marker = fileName.range(of: "-ch") else { return nil }
        let digits = fileName[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}

/// Pure helpers for keeping the rendered-narration directory tidy.
enum NarrationCacheStore {
    /// File names belonging to `bookPrefix` rendered with a voice other than
    /// `currentVoice` — safe to delete when (re)rendering with the new voice.
    static func staleVoiceFiles(
        _ fileNames: [String], bookPrefix: String, currentVoice: VoiceID
    ) -> [String] {
        let keepSuffix = "-\(currentVoice.rawValue).m4a"
        return fileNames.filter { $0.hasPrefix(bookPrefix) && !$0.hasSuffix(keepSuffix) }
    }
}
