// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

enum LibraryCoverStore {
    /// Writes cover bytes under `coversDir`, named with a stable SHA-256 hash of
    /// the book id. Returns the relative filename, or nil when data/write fails.
    nonisolated static func writeCover(
        _ data: Data?,
        id: String,
        coversDir: URL
    ) -> String? {
        guard let data else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: coversDir, withIntermediateDirectories: true)
            let name = coverFilename(for: id)
            try data.write(to: coversDir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    nonisolated static func coverFilename(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}
