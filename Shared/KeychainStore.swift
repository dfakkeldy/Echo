// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

#if DEBUG
    import Synchronization
#endif

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
        case macLastFileBookmark
        case bookmarkNotes
        case absRefreshToken
        case absPinnedCertificate
        case anthropicAPIKey
        case watchInboxWebhook
        // Per-provider AI tokens (`aiProvider.<preset>`). `anthropicAPIKey` is the
        // legacy single-key account, retained only so migration can read and clear it.
        case aiProviderAnthropic = "aiProvider.anthropic"
        case aiProviderDeepSeek = "aiProvider.deepseek"
        case aiProviderKimi = "aiProvider.kimi"
        case aiProviderGLM = "aiProvider.glm"
        case aiProviderCustom = "aiProvider.custom"
    }

    /// Dedicated Keychain service for per-book security-scoped bookmarks so
    /// standalone books picked via the file selector remain reopenable from the
    /// Library page across book switches and device reboots.
    static let bookBookmarkService = "com.echo.audiobooks.book-bookmarks"

    #if DEBUG
        private struct FallbackKey: Hashable {
            let service: String
            let account: String
        }

        // Unsigned simulator test hosts can be denied Keychain writes when CI runs
        // with CODE_SIGNING_ALLOWED=NO. Keep that path volatile and DEBUG-only:
        // release builds never fall back from the Keychain.
        private static let volatileFallback = Mutex<[FallbackKey: Data]>([:])
    #endif

    @discardableResult
    static func set(_ data: Data, for key: Key, service: String = "com.echo.audiobooks") -> Bool {
        set(data, forAccount: key.rawValue, service: service)
    }

    @discardableResult
    static func set(_ data: Data, forAccount account: String, service: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // ...ThisDeviceOnly: security-scoped bookmark data is specific to this
            // device/installation and is meaningless (and a stale-data risk) if
            // synced via iCloud Keychain or restored onto another device (§6.3).
            // AfterFirstUnlock still allows background audio access once unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update-or-add instead of delete-then-add: the old path could lose the
        // data entirely if SecItemAdd failed after a successful delete (§6.3).
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            #if DEBUG
                storeVolatileFallback(data, forAccount: account, service: service)
            #endif
            return false
        }
        let addQuery = baseQuery.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        #if DEBUG
            storeVolatileFallback(data, forAccount: account, service: service)
        #endif
        return false
    }

    /// Reads `Data` from the Keychain for the given key.
    static func data(for key: Key, service: String = "com.echo.audiobooks") -> Data? {
        data(forAccount: key.rawValue, service: service)
    }

    /// Reads `Data` from the Keychain for a dynamic account identifier.
    static func data(forAccount account: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            #if DEBUG
                return volatileFallbackData(forAccount: account, service: service)
            #else
                return nil
            #endif
        }
        return result as? Data
    }

    /// Removes the entry for the given key.
    static func remove(_ key: Key, service: String = "com.echo.audiobooks") {
        remove(account: key.rawValue, service: service)
    }

    /// Removes the entry for a dynamic account identifier.
    static func remove(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        #if DEBUG
            removeVolatileFallback(forAccount: account, service: service)
        #endif
    }

    #if DEBUG
        private static func storeVolatileFallback(
            _ data: Data, forAccount account: String, service: String
        ) {
            let fallbackKey = FallbackKey(service: service, account: account)
            volatileFallback.withLock { storage in
                storage[fallbackKey] = data
            }
        }

        private static func volatileFallbackData(
            forAccount account: String, service: String
        ) -> Data? {
            let fallbackKey = FallbackKey(service: service, account: account)
            return volatileFallback.withLock { storage in
                storage[fallbackKey]
            }
        }

        private static func removeVolatileFallback(forAccount account: String, service: String) {
            let fallbackKey = FallbackKey(service: service, account: account)
            volatileFallback.withLock { storage in
                _ = storage.removeValue(forKey: fallbackKey)
            }
        }
    #endif
}
