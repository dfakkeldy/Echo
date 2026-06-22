// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves a bundled narration resource, allowing an `ECHO_RESOURCE_DIR`
/// environment override so a bare command-line tool (no `.app` bundle) can find
/// the lexicon / phoneme vocab / voice-pack files. The override wins only when it
/// is set AND the file exists there; otherwise this is exactly `Bundle.main`.
enum NarrationResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}
