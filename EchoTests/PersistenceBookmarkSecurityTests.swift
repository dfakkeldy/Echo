// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PersistenceBookmarkSecurityTests {
    @Test func saveBookmarkDoesNotWritePlaintextFallbackWhenKeychainSaveFails() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderURL = try Self.makeBookmarkFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let persistence = Persistence(
            defaults: defaults,
            saveSecurityScopedBookmarkData: { _ in false },
            loadSecurityScopedBookmarkData: { nil }
        )

        let didSave = persistence.saveBookmark(url: folderURL)

        #expect(!didSave)
        #expect(defaults.data(forKey: Persistence.securityScopedBookmarkDefaultsKey) == nil)
    }

    @Test func restoreBookmarkDoesNotUseLegacyPlaintextWhenMigrationFails() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderURL = try Self.makeBookmarkFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let legacyData = try Self.bookmarkData(for: folderURL)
        defaults.set(legacyData, forKey: Persistence.securityScopedBookmarkDefaultsKey)

        let persistence = Persistence(
            defaults: defaults,
            saveSecurityScopedBookmarkData: { _ in false },
            loadSecurityScopedBookmarkData: { nil }
        )

        let restoredURL = persistence.restoreBookmark()

        #expect(restoredURL == nil)
        #expect(defaults.data(forKey: Persistence.securityScopedBookmarkDefaultsKey) == legacyData)
    }

    @Test func restoreBookmarkMigratesLegacyPlaintextOnlyAfterKeychainSuccess() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderURL = try Self.makeBookmarkFolder()
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let legacyData = try Self.bookmarkData(for: folderURL)
        defaults.set(legacyData, forKey: Persistence.securityScopedBookmarkDefaultsKey)

        var migratedData: Data?
        let persistence = Persistence(
            defaults: defaults,
            saveSecurityScopedBookmarkData: { data in
                migratedData = data
                return true
            },
            loadSecurityScopedBookmarkData: { nil }
        )

        let restoredURL = try #require(persistence.restoreBookmark())

        #expect(restoredURL.path == folderURL.path)
        #expect(migratedData == legacyData)
        #expect(defaults.data(forKey: Persistence.securityScopedBookmarkDefaultsKey) == nil)
    }

    @Test func macOSLastFileBookmarkHasDistinctKeychainAccount() {
        #expect(KeychainStore.Key.macLastFileBookmark.rawValue == "macLastFileBookmark")
    }

    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.echo.tests.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func makeBookmarkFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoBookmarkSecurity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

}
