// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

/// Structural guards for the macOS cover-derived theming.
///
/// `MacCoverTintTests` covers the *decision* — it compiles the real resolver and
/// checks what colour comes out. These tests cover the *wiring*, which no unit
/// test can reach: the `Echo macOS` target has no test bundle, so whether a
/// SwiftUI view actually applies the resolved colour is only visible in source
/// text (see `MacSource`).
///
/// Both halves are needed. Two macOS settings previously wrote preferences that
/// no macOS code path read — Theme Color ▸ Artwork silently resolved to the
/// system accent, and Vivid Cover Accent had no consumer at all. A correct
/// resolver nothing calls would have left both of those lies intact.
@Suite("macOS cover theme wiring")
struct MacCoverThemeWiringTests {

    @Test("Artwork accent is applied to the window, not just computed")
    func windowAppliesTheCoverTint() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("player.coverTint("),
            "Theme Color ▸ Artwork must be backed by a real cover tint, not a stored string nothing reads."
        )
        #expect(
            src.contains(".tint(player.coverTint("),
            "The resolved cover accent must reach a .tint modifier; computing it and dropping it is the old bug."
        )
    }

    @Test("Vivid Cover Accent reaches the resolver")
    func vividPreferenceIsConsumed() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("vividAccent: settings.vividCoverAccent"),
            "Vivid Cover Accent must feed the tint resolver; a toggle with no consumer is a lying setting."
        )
    }

    /// The scheme cannot come from the environment alone. `.preferredColorScheme`
    /// publishes upward to the window and only then flows back down, so on the
    /// update where Appearance changes, the environment still reports the
    /// outgoing scheme and the accent would be built against the wrong recipe.
    @Test("Explicit Appearance drives the recipe, environment only fills in System")
    func schemeResolvesFromSettingsFirst() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("Echo_macOSApp.colorScheme(for: settings.appAppearance) ?? colorScheme"),
            "An explicit Light/Dark preference must win over the environment when building cover recipes."
        )
    }

    /// Scope check, not decoration: the wash belongs on player chrome only.
    /// `CoverThemedSheet` states the rule this follows — long-form reading
    /// surfaces stay system-neutral — and `MacReaderFeedView` is the rest of
    /// this pane.
    @Test("The wash is on the transport, and the reader stays neutral")
    func playerBarIsWashedAndTheReaderIsNot() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains(".background(playerBarWash)"),
            "The transport must carry the cover wash.")
        #expect(
            src.contains("player.coverTheme("),
            "The wash must come from the shared cover theme, not a second colour derivation.")
        #expect(
            !src.contains("MacReaderFeedView().background(playerBarWash)"),
            "The reader feed must stay system-neutral; washing long-form text is the rule this pane follows."
        )
    }

    /// The Library listed every book behind the same `book.closed` glyph while
    /// the shelf already stored a cover per row.
    @Test("Library rows show the shelf's own cover")
    func libraryRowsShowRealCovers() throws {
        let src = try MacSource.read("Views/MacLibraryView.swift")
        #expect(
            src.contains("LibraryCoverImage(coverArtPath: book.coverArtPath)"),
            "Library rows must render the stored cover rather than a generic book glyph.")
        #expect(
            src.contains("exclamationmark.triangle"),
            "An unavailable book must keep its warning affordance — the cover cannot carry that signal."
        )
    }
}
