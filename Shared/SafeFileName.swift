import Foundation

/// Produces filesystem-safe directory and file names from identifiers that may
/// contain scheme prefixes, percent-encoding, or other characters unsuitable
/// for paths.
enum SafeFileName {
    /// Returns a sanitized name suitable for use as a directory or file name
    /// component, derived from the given audiobook identifier.
    ///
    /// Removes the `file://` scheme prefix if present, percent-decodes the
    /// remaining string, then replaces characters that are invalid on Apple
    /// filesystems with underscores.
    static func fromAudiobookID(_ id: String) -> String {
        let cleaned: String
        if id.hasPrefix("file://") {
            cleaned = String(id.dropFirst("file://".count))
        } else {
            cleaned = id
        }

        let decoded = cleaned.removingPercentEncoding ?? cleaned
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = decoded.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "_")

        let trimmed = sanitized.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "_" }
        return trimmed
    }
}
