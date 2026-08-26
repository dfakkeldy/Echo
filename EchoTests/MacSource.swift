// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves and reads a source file from the `Echo macOS` target folder for
/// structural (source-scanning) tests. The `Echo macOS` target is not compiled
/// into EchoTests, so behavioral assertions are made against source text. Walks
/// up from #filePath until it finds `Echo macOS/<relativePath>`.
enum MacSource {
    enum MacSourceError: Error { case notFound(String) }

    /// Rewrites source text into a layout-independent form so that substring
    /// assertions survive re-wrapping by the formatter.
    ///
    /// The repo's format-on-edit hook re-runs `swift-format` over the *whole*
    /// file every time any part of it is edited, so an untouched call can be
    /// wrapped differently and break a structural test that never changed.
    /// This has bitten twice (PR #195, PR #501). Each rule below undoes exactly
    /// one place `swift-format` is allowed to insert a break:
    ///
    /// 1. runs of whitespace (including newlines) collapse to one space;
    /// 2. `(`/`[` may be followed by a break — drop the space after them;
    /// 3. `)`/`]` may be preceded by a break, and an exploded collection literal
    ///    also gains a trailing comma — drop both;
    /// 4. a chained `.member` may be wrapped onto its own line — drop the space
    ///    before a dot *that follows a closing delimiter*.
    ///
    /// Rule 4 is deliberately narrow. Removing the space before every dot would
    /// also rewrite leading-dot shorthand, forcing assertions to be spelled
    /// `"design:.monospaced"` instead of `"design: .monospaced"`; anchoring on a
    /// closing delimiter matches only the wrapped-chain shape. Rule 3 folds the
    /// space and the comma into one pass so the result is idempotent: no rule
    /// can re-expose input for an earlier one.
    ///
    /// Assertion literals must be fixed points of this function — a literal
    /// containing e.g. a line break or a doubled space can never match
    /// normalized text, which turns `contains` into a hard failure and
    /// `!contains` into a tautology.
    static func normalized(_ source: String) -> String {
        var text = source.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "([(\\[]) ", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "[ ,]+([)\\]])", with: "$1", options: .regularExpression)
        return text.replacingOccurrences(
            of: "([)\\]}]) \\.", with: "$1.", options: .regularExpression)
    }

    /// - Parameter relativePath: Path under `Echo macOS/`, e.g.
    ///   "Views/MacPlayerModel.swift" or "Echo_macOSApp.swift".
    /// - Returns: The file's contents, whitespace-normalized by
    ///   ``normalized(_:)`` so assertions tolerate formatter line-wrapping.
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
                return normalized(content)
            }
            directory.deleteLastPathComponent()
        }
        throw MacSourceError.notFound(relativePath)
    }
}
