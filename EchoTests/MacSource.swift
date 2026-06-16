// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves and reads a source file from the `Echo macOS` target folder for
/// structural (source-scanning) tests. The `Echo macOS` target is not compiled
/// into EchoTests, so behavioral assertions are made against source text. Walks
/// up from #filePath until it finds `Echo macOS/<relativePath>`.
enum MacSource {
    enum MacSourceError: Error { case notFound(String) }

    /// - Parameter relativePath: Path under `Echo macOS/`, e.g.
    ///   "Views/MacPlayerModel.swift" or "Echo_macOSApp.swift".
    static func read(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("Echo macOS")
                .appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw MacSourceError.notFound(relativePath)
    }
}
