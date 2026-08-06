// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves a bundled narration resource, allowing an `ECHO_RESOURCE_DIR`
/// environment override so a bare command-line tool (no `.app` bundle) can find
/// the lexicon / phoneme vocab / voice-pack files. The override wins only when it
/// is set AND the file exists there; otherwise this is exactly `Bundle.main`.
nonisolated enum NarrationResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        url(forResource: name, withExtension: ext, subdirectory: nil)
    }

    static func url(
        forResource name: String, withExtension ext: String, subdirectory: String?
    ) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
            let root = URL(fileURLWithPath: dir)
            let directories =
                subdirectory.map {
                    [root.appendingPathComponent($0, isDirectory: true), root]
                } ?? [root]
            for directory in directories {
                let candidate = directory.appendingPathComponent(
                    ext.isEmpty ? name : "\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return Bundle.main.url(
            forResource: name, withExtension: ext.isEmpty ? nil : ext,
            subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext)
    }
}
