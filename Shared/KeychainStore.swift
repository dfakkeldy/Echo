import Foundation
import Security

/// Thin wrapper around the iOS / macOS Keychain for securely storing small
/// blobs of data (security-scoped bookmark data, bookmark notes with private
/// metadata, etc.) that should not live in unencrypted UserDefaults.
///
/// **§6.2 Migration path:**
/// 1. Move `Persistence.bookmarkStore` (security-scoped bookmark data)
///    from `UserDefaults.standard` to `KeychainStore[.securityScopedBookmark]`.
/// 2. Move bookmark records with notes / voice-memo metadata from
///    UserDefaults to the App Group SQLite database (GRDB-managed).
/// 3. Keep non-sensitive keys (progress, speed, ordering) in UserDefaults.
enum KeychainStore {
    enum Key: String {
        case securityScopedBookmark
        case bookmarkNotes
    }

    @discardableResult
    static func set(_ data: Data, for key: Key, service: String = "com.echo.audiobooks") -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            // kSecAttrAccessibleAfterFirstUnlock allows background access
            // (e.g., background audio playback) after the device has been
            // unlocked once, without requiring the device to be unlocked
            // at the exact moment of access.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads `Data` from the Keychain for the given key.
    static func data(for key: Key, service: String = "com.echo.audiobooks") -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Removes the entry for the given key.
    static func remove(_ key: Key, service: String = "com.echo.audiobooks") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
