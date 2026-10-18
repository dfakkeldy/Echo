// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Guards the source-reading seam used by the macOS parity suites.
///
/// Those suites assert on macOS source *text*, and the repo's format-on-edit
/// hook re-runs `swift-format` over the whole file on every edit — so editing
/// one part of a file can re-wrap an untouched call and break an assertion that
/// never changed (PR #195, PR #501). `MacSource.normalized(_:)` removes that
/// coupling; these tests pin the shapes it must and must not collapse.
struct MacSourceNormalizationTests {
    /// The PR #501 regression: `swift-format` breaks after `(` when the call
    /// exceeds the 100-column limit, which must not hide the call from a
    /// single-line assertion.
    @Test func wrappedCallArgumentsMatchSingleLineNeedle() {
        let wrapped = """
            self.importPendingCompanionDocumentsIfNeeded(
                for: url, loadedChapters: parsed, loadedDuration: loadedDuration)
            """
        let needle =
            "importPendingCompanionDocumentsIfNeeded(for: url, loadedChapters: parsed, loadedDuration: loadedDuration)"

        #expect(
            MacSource.normalized(wrapped).contains(MacSource.normalized(needle)),
            "A call wrapped after its opening paren must still match the inline assertion.")
    }

    /// `swift-format` breaks *before* a chained `.member`, leaving a space that
    /// a plain whitespace collapse cannot remove.
    @Test func wrappedModifierChainMatchesInlineNeedle() {
        let wrapped = """
            Button("Connect") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(serverURLText.isEmpty)
            """

        #expect(
            MacSource.normalized(wrapped)
                .contains("}.buttonStyle(.borderedProminent).disabled(serverURLText.isEmpty)"),
            "A wrapped SwiftUI modifier chain must still match an inline assertion.")
    }

    /// Exploding a collection literal across lines makes `swift-format` append a
    /// trailing comma, which must not defeat an inline assertion.
    @Test func explodedCollectionLiteralMatchesInlineNeedle() {
        let wrapped = """
            ScrollView([
                .vertical, .horizontal,
            ])
            """

        #expect(
            MacSource.normalized(wrapped).contains("ScrollView([.vertical, .horizontal])"),
            "A collection literal exploded across lines must still match its inline form.")
    }

    /// Rule 4 is anchored on a closing delimiter on purpose. Removing the space
    /// before *every* dot would force assertions to be written
    /// `"design:.monospaced"`; keep leading-dot shorthand readable.
    @Test func leadingDotShorthandKeepsItsSpace() {
        for literal in [
            "var loopMode: LoopMode = .off",
            ".font(.system(.callout, design: .monospaced))",
            "ScrollView([.vertical, .horizontal])",
            "ThemeColor(rawValue: themeColor)?.color ?? .accentColor",
            "if case .code(let text, _) = snapshot.visualCue?.content",
        ] {
            #expect(
                MacSource.normalized(literal) == literal,
                "Assertion literals must be fixed points of the normalizer: \(literal)")
        }
    }

    /// Normalizing already-normalized text must not drift, otherwise a literal
    /// that is a fixed point today could stop matching tomorrow.
    @Test func normalizationIsIdempotent() throws {
        let source = try MacSource.read("Views/MacPlayerModel.swift")

        #expect(MacSource.normalized(source) == source)

        // A fully exploded argument list exercises every rule at once: the
        // space after `(`, and the space *and* trailing comma before `)`.
        let exploded = """
            configure(
                first: a,
                second: b,
            )
            """
        let once = MacSource.normalized(exploded)

        #expect(once == "configure(first: a, second: b)")
        #expect(MacSource.normalized(once) == once)
    }

    /// `MacSource.read` must hand back normalized text, not raw file contents.
    @Test func readReturnsNormalizedText() throws {
        let source = try MacSource.read("Views/MacTriPaneView.swift")

        #expect(!source.contains("\n"), "Reader output must not contain line breaks.")
        #expect(!source.contains("  "), "Reader output must not contain doubled spaces.")
        #expect(
            source.contains("struct MacTriPaneView"),
            "Normalization must preserve the source's tokens.")
    }
}
