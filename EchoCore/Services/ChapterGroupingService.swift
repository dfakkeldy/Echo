import Foundation

// MARK: - ChapterGroupingResult

/// The output of `ChapterGroupingService.group(_:)`.
struct ChapterGroupingResult {
    /// Collapsed logical chapters suitable for navigation and display.
    let logicalChapters: [Chapter]
    /// Map from logical chapter index → original fine-grained sub-section atoms.
    /// Non-empty only when grouping was applied.
    let sections: [Int: [Chapter]]
    /// `true` when at least one grouping was applied (i.e. two or more consecutive
    /// atoms shared the same logical base title).
    let wasGrouped: Bool
}

// MARK: - ChapterGroupingService

/// Detects and collapses Libation-style sub-section chapter atoms.
///
/// Libation encodes audiobooks with very fine-grained chapter atoms whose titles
/// share a common prefix and differ only by a trailing section suffix, e.g.:
///
/// ```
/// "Part III. Trust and Autonomy: Chapter 11. A"
/// "Part III. Trust and Autonomy: Chapter 11. B"
/// "Part III. Trust and Autonomy: Chapter 11. C"
/// ```
///
/// `group(_:)` strips the suffix, groups consecutive atoms with the same base
/// title, and collapses each group into a single `Chapter` that spans the full
/// time range of the group.  The original atoms are retained in `sections` so
/// the scrubber can render hairline tick marks at their boundaries.
struct ChapterGroupingService {

    // MARK: - Public API

    /// Groups `chapters` by their logical base title.
    ///
    /// - Parameter chapters: The raw `[Chapter]` array from `ChapterService.parseChapters`.
    /// - Returns: A `ChapterGroupingResult`.  When no grouping is needed
    ///   (`wasGrouped == false`) `logicalChapters` equals the input and `sections` is empty.
    static func group(_ chapters: [Chapter]) -> ChapterGroupingResult {
        guard chapters.count >= 2 else {
            return ChapterGroupingResult(logicalChapters: chapters, sections: [:], wasGrouped: false)
        }

        var logicalChapters: [Chapter] = []
        var sections: [Int: [Chapter]] = [:]
        
        var groupAtoms: [Chapter] = []
        var currentBaseTitle: String? = nil

        func flushGroup() {
            guard let first = groupAtoms.first, let last = groupAtoms.last else { return }
            let logicalIndex = logicalChapters.count
            let logicalTitle = currentBaseTitle ?? first.title
            let collapsed = Chapter(
                index: logicalIndex,
                title: logicalTitle,
                startSeconds: first.startSeconds,
                endSeconds: last.endSeconds,
                isEnabled: groupAtoms.allSatisfy { $0.isEnabled }
            )
            logicalChapters.append(collapsed)
            if groupAtoms.count > 1 {
                sections[logicalIndex] = groupAtoms
            }
            groupAtoms.removeAll()
        }

        for chapter in chapters {
            let rawTitle = chapter.title ?? ""
            let strippedTitle = logicalBaseTitle(for: rawTitle)
            
            if groupAtoms.isEmpty {
                groupAtoms.append(chapter)
                currentBaseTitle = strippedTitle
                continue
            }
            
            var belongsToGroup = false
            if strippedTitle == currentBaseTitle {
                belongsToGroup = true
            } else if let base = currentBaseTitle, !base.isEmpty, rawTitle.hasPrefix(base + ":") {
                // Handle Libation hierarchical pattern: "Base Title: Sub-section Title"
                belongsToGroup = true
            }
            
            if belongsToGroup {
                groupAtoms.append(chapter)
            } else {
                flushGroup()
                groupAtoms.append(chapter)
                currentBaseTitle = strippedTitle
            }
        }
        flushGroup()

        let wasGrouped = !sections.isEmpty
        return ChapterGroupingResult(
            logicalChapters: logicalChapters,
            sections: wasGrouped ? sections : [:],
            wasGrouped: wasGrouped
        )
    }

    // MARK: - Title normalisation

    /// Strips a trailing Libation-style sub-section suffix from `title` and returns
    /// the logical base title.
    ///
    /// Handled patterns (applied in order, first match wins):
    /// - `. A` through `. Z` — single uppercase letter suffix (most common)
    /// - `. 1` through `. 99` — numeric suffix
    /// - ` (Part 1)` / ` (Part A)` — parenthesised part label
    static func logicalBaseTitle(for title: String) -> String {
        // Pattern 1: trailing ". <single uppercase letter>" e.g. ". A", ". B"
        if let stripped = strip(title, pattern: #"\.\s+[A-Z]$"#) {
            return stripped.trimmingCharacters(in: .whitespaces)
        }
        // Pattern 2: trailing ". <digits>" e.g. ". 1", ". 12"
        if let stripped = strip(title, pattern: #"\.\s+\d+$"#) {
            return stripped.trimmingCharacters(in: .whitespaces)
        }
        // Pattern 3: trailing " (Part <N>)" or " (Part <Letter>)"
        if let stripped = strip(title, pattern: #"\s+\(Part\s+[A-Z0-9]+\)$"#) {
            return stripped.trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    // MARK: - Private

    private static func strip(_ string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string) else {
            return nil
        }
        return String(string[string.startIndex..<range.lowerBound])
    }
}
