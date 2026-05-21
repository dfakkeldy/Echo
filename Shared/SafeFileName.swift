import Foundation

/// Sanitizes audiobook identifiers into filesystem-safe names.
/// Audiobook IDs are often `file://` URLs — this helper strips the scheme
/// and replaces path separators so the result is safe for use in filenames
/// and directory names across chapter artwork caches, EPUB asset folders,
/// and any future derived asset paths.
enum SafeFileName {
    static func fromAudiobookID(_ id: String) -> String {
        let cleaned = id
            .replacingOccurrences(of: "file://", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let filtered = cleaned.unicodeScalars.filter { allowed.contains($0) }
        let scalarLimit = 128
        let trimmed = String(filtered.prefix(scalarLimit))
        guard !trimmed.isEmpty else { return "unknown" }
        return trimmed
    }
}
