// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which reading surface a book presents in the Read tab.
enum ReaderSurfaceMode: String, CaseIterable, Sendable {
    /// The original visual PDF page (`PDFDocumentView`).
    case page
    /// The reflow text card feed (`ReaderTab`), with read-along highlight.
    case reflow
}

/// Pure resolver for which reading surfaces a book can offer. Mirrors the
/// style of `TimelineIngestionFactory.strategy(...)` — no DB, no async, just
/// availability flags in, surfaces out.
///
/// A parsed PDF has visible `epub_block` rows (so `hasEPUB`/`hasReflowableBlocks`
/// is true) AND a `.pdf` file, which is why it can present both surfaces.
enum ReaderSurfaceResolver {
    /// Surfaces a book can present, in display order. Empty for non-PDF books
    /// (EPUB/text/transcript keep their single existing surface).
    /// - A parsed PDF (`hasPDF && hasReflowableBlocks`) → `[.page, .reflow]`.
    /// - A PDF with no parsed text (companion-to-external-audio, or scanned)
    ///   → `[.page]`.
    static func availableModes(hasPDF: Bool, hasReflowableBlocks: Bool) -> [ReaderSurfaceMode] {
        guard hasPDF else { return [] }
        return hasReflowableBlocks ? [.page, .reflow] : [.page]
    }

    /// True when the user should see a page⇄reflow toggle (both surfaces exist).
    static func offersToggle(hasPDF: Bool, hasReflowableBlocks: Bool) -> Bool {
        availableModes(hasPDF: hasPDF, hasReflowableBlocks: hasReflowableBlocks).count > 1
    }
}
