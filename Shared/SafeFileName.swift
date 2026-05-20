import Foundation

/// Produces filesystem-safe names from audiobook identifiers.
/// Audiobook IDs are URL strings (e.g. `file:///path/to/My Book/`)
/// which contain characters invalid in filenames (`/`, `:`).
///
/// Usage:
/// ```swift
/// let dir = "ChapterArtwork"
/// let name = SafeFileName.fromAudiobookID(audiobookID)
/// let path = cacheDir.appendingPathComponent("\(name)_ch0.jpg")
/// ```
enum SafeFileName {

    /// Converts an audiobook identifier into a safe filename component.
    ///
    /// - For `file://` URLs: strips the scheme and authority, then converts
    ///   path separators to hyphens.
    /// - For plain strings: returns the string as-is if already safe.
    /// - For empty input: returns a stable placeholder.
    static func fromAudiobookID(_ id: String) -> String {
        guard !id.isEmpty else { return "unknown-audiobook" }

        // Strip file:// prefix if present
        var cleaned = id
        if cleaned.hasPrefix("file://") {
            cleaned = String(cleaned.dropFirst(7))
        }

        // Replace path separators and colons (common in URL-derived IDs)
        let unsafeChars: [Character] = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        var result = ""
        result.reserveCapacity(cleaned.utf8.count)

        for char in cleaned {
            if unsafeChars.contains(char) {
                result.append("-")
            } else {
                result.append(char)
            }
        }

        // Trim leading/trailing hyphens and whitespace
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard !trimmed.isEmpty else { return "unknown-audiobook" }
        return trimmed
    }
}
