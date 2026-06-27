// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct SecurityScopeManagerLibraryRootTests {
    @Test func libraryRootSlotTracksAndSwapsWithoutCrashing() throws {
        let manager = SecurityScopeManager()
        let tmpA = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-a-\(UUID().uuidString)", isDirectory: true)
        let tmpB = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpA)
            try? FileManager.default.removeItem(at: tmpB)
        }

        manager.startLibraryRoot(url: tmpA)
        manager.startLibraryRoot(url: tmpA)
        manager.startLibraryRoot(url: tmpB)
        manager.stopLibraryRoot()
        manager.stopLibraryRoot()
        manager.stopAll()
    }
}
