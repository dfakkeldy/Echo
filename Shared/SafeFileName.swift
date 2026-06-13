import CryptoKit
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

        guard !filtered.isEmpty else { return "unknown" }
        if filtered.count <= scalarLimit {
            return String(filtered)
        }

        // Audiobook IDs are file URLs whose unique part (the book folder)
        // comes *last*, so plain truncation collapses distinct books onto one
        // name — colliding their caches and image-asset directories. Keep a
        // readable prefix and append a stable digest of the full ID.
        // (SHA-256, not `Hasher` — derived paths are recomputed across
        // launches and `Hasher` is per-process seeded.)
        let digest = SHA256.hash(data: Data(id.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let prefix = String(filtered.prefix(scalarLimit - suffix.count - 1))
        return "\(prefix)-\(suffix)"
    }

    /// Strips filesystem-reserved characters from a display name (deck / book /
    /// note title) so it is safe as a file or directory name in an export.
    /// Distinct from `fromAudiobookID`, which hashes `file://` identifiers — this
    /// preserves the readable name and only removes invalid characters.
    static func sanitizeForFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }
}
