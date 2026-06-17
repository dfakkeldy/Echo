// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where rendered narration audio lives, shared by iOS + macOS. Application
/// Support (not Caches, so iOS won't purge a queued chapter mid-play) under a
/// `Narration` subfolder, excluded from iCloud/iTunes backup since it's
/// regenerable. Relocated from the iOS-only
/// `PlayerModel.narrationCacheDirectory()` so the macOS batch queue can write
/// rendered chapters to the same place the player reads them from.
enum NarrationCache {
    /// App-owned, durable directory for rendered narration audio. Created on
    /// first access and flagged `isExcludedFromBackup`.
    static func directory() -> URL {
        let fm = FileManager.default
        var base =
            (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory)
            .appendingPathComponent("Narration", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }
}
