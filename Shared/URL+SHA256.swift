import Foundation
import CryptoKit

extension URL {
    /// Stable SHA-256 hash of the file path, used as a cache key for transcripts
    /// and other per-file derived data.
    var sha256Hash: String {
        let data = Data(path.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
