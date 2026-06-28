// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct DatabaseServiceAppGroupFallbackTests {
    @Test func missingAppGroupStillThrowsWhenFallbackIsDisabled() throws {
        let identifier = "group.invalid.echo.tests.\(UUID().uuidString)"

        #expect(throws: DatabaseError.self) {
            _ = try DatabaseService(
                appGroupIdentifier: identifier,
                appGroupFallbackDirectory: nil,
                allowAppGroupFallback: false
            )
        }
    }

    @Test func missingAppGroupCanUseExplicitDebugFallbackDirectory() throws {
        let identifier = "group.invalid.echo.tests.\(UUID().uuidString)"
        let fallbackRoot = FileManager.default.temporaryDirectory
            .appending(path: "EchoDatabaseFallbackTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fallbackRoot) }

        let service = try DatabaseService(
            appGroupIdentifier: identifier,
            appGroupFallbackDirectory: fallbackRoot,
            allowAppGroupFallback: true
        )

        #expect(service.dbPath.hasPrefix(fallbackRoot.path))
        #expect(FileManager.default.fileExists(atPath: service.dbPath))
    }
}
