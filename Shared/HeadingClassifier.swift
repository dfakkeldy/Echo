import Foundation

/// Unified classification of EPUB heading text.
///
/// Import, the reader feed, and the TOC sheet must agree on what counts as a
/// real content heading. These rules previously existed as three divergent
/// copies, so junk filtered from one surface still appeared on another.
enum HeadingClassifier {

    /// Utility callout boxes ("Tip", "Warning", …) that publishers mark up
    /// with heading tags.
    static func isUtilityCallout(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return ["tip", "warning", "note", "caution", "important"].contains(lower)
    }

    /// Figure/table/image captions promoted to headings by some EPUBs.
    static func isFigureCaption(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("figure ") || lower.hasPrefix("table ") || lower.hasPrefix("image ")
    }

    /// Returns `true` when a heading matches common front-matter or
    /// back-matter patterns that should not become chapters or section splits.
    ///
    /// EPUBs often contain pages like "Title Page", "Copyright", "Contents",
    /// "Also by…" whose headings surface as junk chapters. This set-based
    /// check catches the most common patterns without being so broad that it
    /// swallows legitimate chapter titles ("Foreword" and "Introduction" are
    /// intentionally kept as content).
    static func isNonContent(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        /// Headings that are almost never real chapter content.
        let nonContentExact: Set<String> = [
            // Cover pages
            "cover", "back cover", "cover page",
            // Title / half-title pages
            "title page", "title", "half title", "half-title",
            // Copyright / colophon
            "copyright", "copyright page", "colophon",
            // Dedication / epigraph
            "dedication", "dedications", "epigraph",
            // Table of contents
            "contents", "table of contents", "toc",
            // Publisher / promotional
            "also by", "also by the author", "also available",
            "praise for", "praise", "coming soon",
            "about the publisher", "credits",
            // Lists of figures / tables
            "list of illustrations", "list of figures", "list of tables",
            "cast of characters", "maps", "timeline",
            // Explicit front matter marker
            "front matter", "frontmatter",
            // Bibliographic / index
            "bibliography", "references", "index", "glossary",
            // End notes
            "endnotes", "notes", "footnotes",
            // Author bio
            "about the author", "about the authors",
        ]

        if nonContentExact.contains(lower) {
            return true
        }

        // Prefix checks for variable patterns like "Also by J.R.R. Tolkien"
        let nonContentPrefixes = [
            "also by ", "praise for ", "excerpt from ", "excerpt: ",
            "about the author", "about the publisher",
        ]
        for prefix in nonContentPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    /// Combined junk check used wherever heading blocks become navigation:
    /// utility callouts, over-long pseudo-headings, figure captions, and
    /// non-content front/back-matter titles.
    static func isJunk(_ text: String) -> Bool {
        text.count > 100
            || isUtilityCallout(text)
            || isFigureCaption(text)
            || isNonContent(text)
    }
}
