// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Analyzes EPUB XHTML blocks to infer structural semantics (e.g. what is a heading
/// vs a paragraph) using a heuristic scoring approach.
nonisolated struct EPUBHeuristicEngine {
    let tocLabels: [String]
    let spineItemCount: Int

    // Frequency map of CSS classes used on heading-like elements.
    var cssFrequencyMap: [String: Int] = [:]

    init(tocLabels: [String], spineItemCount: Int) {
        self.tocLabels = tocLabels
        self.spineItemCount = spineItemCount
    }

    /// Pass 1: Build the CSS Fingerprint Map
    /// Scans all blocks across the entire book to build a frequency map of class names.
    mutating func buildCSSFingerprint(from blocks: [TextBlockDescriptor]) {
        for block in blocks {
            let isHeading = block.rawTags.lowercased().hasPrefix("h")
            let textCount = block.text?.count ?? 0
            let isShort = textCount > 0 && textCount < 100

            // Only consider headings or short structural blocks to prevent diluting the map with generic body text
            if isHeading || isShort {
                for className in block.rawClasses {
                    cssFrequencyMap[className, default: 0] += 1
                }
            }
        }
    }

    /// Pass 2: The Scoring Engine
    /// Assigns EPubBlockRecord.Kind based on heuristic signals.
    func score(block: TextBlockDescriptor) -> EPubBlockRecord.Kind {
        // We only modify paragraph/heading types. Images and other types are left alone.
        guard block.kind == .paragraph || block.kind == .heading else {
            return block.kind
        }

        let cleanText = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanText.isEmpty {
            return .paragraph
        }

        let tag = block.rawTags.lowercased()
        // An explicit XHTML heading is a publisher structure signal. Its length
        // and CSS frequency must not turn it back into body text.
        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
            return .heading
        }

        // A publisher TOC label is stronger evidence than visual heuristics,
        // including for unusually long section titles.
        if tocLabels.contains(where: { $0.caseInsensitiveCompare(cleanText) == .orderedSame }) {
            return .heading
        }

        // The prefix and CSS cues below can otherwise promote whole prose
        // paragraphs ("Part of ...", "Chapter 2 is about ...") into headings.
        // A long unpunctuated label can still be a printed TOC heading; a
        // long passage containing a period is prose-like.
        if cleanText.count >= 120 && cleanText.contains(".") {
            return .paragraph
        }

        var score = 0

        let words = cleanText.split(whereSeparator: \.isWhitespace)
        let titleCasedLabel =
            words.count >= 2
            && (words[0].lowercased() == "chapter" || words[0].lowercased() == "part")
            && words[1].first?.isUppercase == true
            && !cleanText.contains(".")
        // Split printed titles can leave a short continuation such as
        // "Chapter of a Story" in its own paragraph tag.
        let shortChapterLabel =
            words.count >= 2 && words[0] == "Chapter" && cleanText.count < 60
            && !cleanText.contains(".")

        // A numbered chapter/part label is useful evidence on paragraph tags.
        // Publishers also use spelled-out numbers and "CHAPTER: 1". The
        // number or titlecase cue keeps phrases such as "Part of ..." out.
        if cleanText.range(
            of:
                "^(?:chapter|part)\\s*:?\\s+(?:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            score += 70
        } else if titleCasedLabel || shortChapterLabel {
            score += 70
        }

        // CSS Class Frequency Match (+60)
        for className in block.rawClasses {
            if let count = cssFrequencyMap[className] {
                // Heuristic: if it's used roughly once per spine item, it's highly likely a structural heading.
                if count > 0 && count <= (spineItemCount + 5) {
                    score += 60
                    break
                }
            }
        }

        // Visual formatting: ALL CAPS (+20)
        if cleanText == cleanText.uppercased() && cleanText.count > 3
            && cleanText.rangeOfCharacter(from: .letters) != nil
        {
            score += 20
        }

        // Visual formatting: Very Short Line (+15)
        if cleanText.count < 60 {
            score += 15
        }

        // Determine kind based on score threshold
        // 80 points is the threshold to become a heading.
        if score >= 80 {
            return .heading
        } else {
            return .paragraph
        }
    }
}
