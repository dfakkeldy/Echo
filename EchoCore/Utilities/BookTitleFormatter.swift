// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Formats human-facing book titles for chrome (the player eyebrow, the
/// book-settings header). Track/file names are often dash-slugs
/// ("system-that-does-the-reviewing"), and the library's `AudiobookRecord.title`
/// can be seeded from the same slug before metadata enrichment runs — so every
/// candidate is passed through `humanized` before display.
// `nonisolated`: pure string formatting, unit-tested off the main actor.
nonisolated enum BookTitleFormatter {

    /// Persisted metadata title first, else the folder/file name — both
    /// humanized (a real title with spaces passes through untouched).
    static func displayTitle(storedTitle: String?, fallbackName: String) -> String {
        let stored = storedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return humanized(stored.isEmpty ? fallbackName : stored)
    }

    /// Turns space-less dash/underscore slugs into spaced Title Case while
    /// preserving interior capitals ("m4b" → "M4b", "EPUB" stays "EPUB").
    /// Names that already contain a space are returned unchanged — they are
    /// human-authored, not slugs.
    static func humanized(_ name: String) -> String {
        guard !name.contains(" ") else { return name }
        let spaced = name.replacing("-", with: " ").replacing("_", with: " ")
        let words = spaced.split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? name : joined
    }
}
