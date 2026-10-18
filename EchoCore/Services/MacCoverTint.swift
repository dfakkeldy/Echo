// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The app-wide accent the macOS window should be tinted with.
///
/// This is the Mac twin of `PlayerModel.resolvedTint(for:)`, and it lives here
/// rather than on `MacPlayerModel` for the same reason `MacChapterLoopDecision`
/// does: there is no macOS unit-test target, so a Mac decision is only testable
/// if it is a pure function compiled into `EchoTests`.
///
/// Keeping it a mirror rather than a re-derivation is the point. Both platforms
/// call the same `CoverThemeBuilder`, so the same book resolves to the same
/// accent on a phone and on a Mac — which is the property
/// `MacCoverTintTests.artworkMatchesTheSharedBuilder` pins.
// `nonisolated`: pure theme lookup, no main-actor state. Under Swift 6 default
// MainActor isolation it would be inferred `@MainActor`, blocking the tests.
nonisolated enum MacCoverTint {

    /// The tint for a stored `themeColor` preference, or `nil` to leave the OS
    /// default in place.
    ///
    /// `.artwork` deliberately never returns `nil`, matching iOS: a cover with
    /// no usable hue resolves through `CoverThemeBuilder`'s neutral fallback,
    /// which seeds from the asset catalog's accent and then contrast-enforces
    /// it. That is a near-brand accent rather than the raw system one, and
    /// re-deriving it here instead of falling through to `.accentColor` is what
    /// keeps the two platforms agreeing on greyscale covers.
    ///
    /// - Parameters:
    ///   - themeColor: the raw `SettingsManager.themeColor` string. An
    ///     unrecognized value falls back to `.artwork`, as it does on iOS.
    ///   - signature: the current cover's identity hues; `nil` (no artwork
    ///     loaded) is treated as the neutral signature.
    ///   - vividAccent: the `Vivid Cover Accent` preference. Strictly additive —
    ///     it can refine a promotion but never loses one the bucket means earn.
    ///   - scheme: the resolved light/dark scheme; the recipes differ per scheme.
    static func tint(
        themeColor: String,
        signature: CoverSignature?,
        vividAccent: Bool,
        scheme: ColorScheme
    ) -> Color? {
        tint(
            themeColor: themeColor,
            coverTheme: theme(signature: signature, vividAccent: vividAccent, scheme: scheme))
    }

    /// The same decision over an already-built theme, so a caller that also
    /// needs the wash pays for one `CoverThemeBuilder` pass instead of two.
    static func tint(themeColor: String, coverTheme: CoverTheme) -> Color? {
        switch ThemeColor(rawValue: themeColor) ?? .artwork {
        case .artwork:
            return coverTheme.accent
        case .system:
            return nil
        case let theme:
            return theme.color
        }
    }

    /// The cover's full set of roles — accent, wash, chip — for washing chrome.
    ///
    /// Deliberately independent of the Theme Color preference, matching
    /// `PlayerModel.coverTheme`: choosing a static accent changes the accent,
    /// not which book you are reading, so the wash keeps following the cover.
    /// Missing artwork resolves through the designed neutral theme rather than
    /// disabling the wash, which is what keeps the chrome from flickering
    /// between washed and bare as covers load.
    static func theme(
        signature: CoverSignature?, vividAccent: Bool, scheme: ColorScheme
    ) -> CoverTheme {
        CoverThemeBuilder.build(
            from: signature ?? .neutral, scheme: scheme, vividAccent: vividAccent)
    }
}
