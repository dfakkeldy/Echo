// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationCacheTests {
    @Test func directoryIsUnderApplicationSupportNarration() throws {
        let dir = NarrationCache.directory()
        #expect(dir.lastPathComponent == "Narration")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func directoryIsExcludedFromBackup() throws {
        let dir = NarrationCache.directory()
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
