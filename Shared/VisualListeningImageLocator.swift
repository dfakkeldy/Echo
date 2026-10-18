// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves stored EPUB image asset paths. Paths are persisted absolute at
/// import time, so a moved/reinstalled app container leaves stale prefixes;
/// the fallback re-roots `<dir>/<filename>` under the current EPUBAssets
/// container — the same recovery the live stage has always used.
nonisolated enum VisualListeningImageLocator {
    static func resolvedURL(forStoredPath imagePath: String) -> URL? {
        let stored = URL(fileURLWithPath: imagePath)
        if FileManager.default.fileExists(atPath: stored.path) { return stored }

        let filename = stored.lastPathComponent
        let dirName = stored.deletingLastPathComponent().lastPathComponent
        let fallback = URL.applicationSupportDirectory
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent(dirName)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
