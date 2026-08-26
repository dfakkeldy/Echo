// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation

/// Where a caption/subtitle may be cut when it cannot be shrunk to fit.
///
/// Captions cut at composed-character (grapheme) boundaries; simple subtitles
/// cut at whitespace-delimited word boundaries. Both always append a literal
/// `…` and re-measure so the ellipsized result honours the line limit.
nonisolated enum SlideshowTextTruncationBoundary: Equatable, Sendable {
    case composedCharacter
    case word
}

/// The result of fitting a single caption or simple-subtitle block into a
/// rectangle: the text to draw, the chosen point size, and whether it had to be
/// ellipsized. `displayText == text` and `isTruncated == false` when the block
/// fit at some size in `[minimum, preferred]`. The source string is never
/// mutated — `displayText` is a fresh trimmed value.
nonisolated struct SlideshowFittedText: Equatable, Sendable {
    let displayText: String
    let fontSize: CGFloat
    let isTruncated: Bool
}

/// A single source word placed on a karaoke page, with the `NSRange` it occupies
/// inside that page's `displayText`. `sourceIndex` is the word's index in the
/// full, untruncated subtitle (the same index space as `WordTokenizer` and
/// word-timing), so the renderer can highlight `activeWordIndex` by mapping it to
/// the matching displayed range.
nonisolated struct SlideshowDisplayedWord: Equatable, Sendable {
    let sourceIndex: Int
    let displayRange: NSRange
}

/// One stable page of a paginated karaoke subtitle. Pages partition the source
/// words in reading order; `sourceWordRange` is the half-open range of source
/// indices on this page. `displayText` includes any required leading/trailing
/// `…`, and `displayedWords` locates every source word within it.
nonisolated struct SlideshowKaraokePage: Equatable, Sendable {
    let displayText: String
    let sourceWordRange: Range<Int>
    let displayedWords: [SlideshowDisplayedWord]
}

/// Pure CoreText text fitting for the slideshow exporter.
///
/// Two responsibilities, both deterministic and side-effect free:
///
/// 1. `fit(_:in:...)` — shrink a caption or simple subtitle from its preferred
///    size toward the profile minimum in fixed 0.5-pt steps, and, only if it
///    still overflows at the minimum, ellipsize it at the requested boundary.
/// 2. `karaokePages(for:in:...)` — divide an overflowing subtitle into stable,
///    word-aligned pages that each fit the line limit, computed once with
///    conservative all-bold metrics so per-word styling can never re-wrap them.
///
/// **Font matching is load-bearing.** The renderer draws caption/subtitle glyphs
/// with `HelveticaNeue` (regular) and `HelveticaNeue-Bold`. This fitter measures
/// `fit(...)` with the *regular* face at the trial size, and computes karaoke
/// page boundaries with the *bold* face (treating every token as bold is the
/// conservative worst case, since the active word is drawn bold while the rest
/// are regular). Task 5 draws with these same fonts, so the measurements
/// describe the glyphs that are actually rasterized.
///
/// CoreText / CoreGraphics / Foundation only — compiles for iOS, macOS, echo-cli,
/// and the Widget (never Watch); no UIKit/AppKit/SwiftUI.
nonisolated enum SlideshowTextFitter {
    // Must match SlideshowFrameRenderer's font names exactly.
    private static let regularFontName = "HelveticaNeue"
    private static let boldFontName = "HelveticaNeue-Bold"
    /// Horizontal ellipsis (U+2026), the literal overflow marker.
    private static let ellipsis = "\u{2026}"
    /// Fixed shrink increment (spec: "decrement in fixed 0.5-pixel steps").
    private static let shrinkStep: CGFloat = 0.5
    /// A height tall enough to hold any realistic wrapped line stack when we
    /// count lines; never a binding constraint by itself.
    private static let measurementHeight: CGFloat = 100_000
    /// Sub-pixel slack so exact-boundary rounding does not flip a fit decision.
    private static let epsilon: CGFloat = 0.5

    // MARK: - fit

    /// Fit `text` into `rect`, shrinking from `preferredFontSize` toward
    /// `minimumFontSize` in 0.5-pt steps and choosing the greatest fitting size.
    /// If nothing fits down to the minimum, ellipsize at `truncationBoundary`
    /// and return the trimmed result at the minimum size.
    static func fit(
        _ text: String,
        in rect: CGRect,
        preferredFontSize: CGFloat,
        minimumFontSize: CGFloat,
        maximumLineCount: Int,
        truncationBoundary: SlideshowTextTruncationBoundary
    ) -> SlideshowFittedText {
        guard !text.isEmpty else {
            return SlideshowFittedText(
                displayText: text, fontSize: preferredFontSize, isTruncated: false)
        }

        // Clean 0.5-pt steps from preferred down to (but not below) the minimum,
        // then the minimum itself as an exact floor. Descending order means the
        // first fitting candidate is the greatest fitting size.
        for size in trialSizes(preferred: preferredFontSize, minimum: minimumFontSize)
        where fits(
            text, fontName: regularFontName, fontSize: size, rect: rect,
            maxLines: maximumLineCount)
        {
            return SlideshowFittedText(
                displayText: text, fontSize: size, isTruncated: false)
        }

        // Still overflows at the minimum size: ellipsize at the requested
        // boundary, always at the minimum size.
        let truncated = truncate(
            text, rect: rect, fontSize: minimumFontSize,
            maxLines: maximumLineCount, boundary: truncationBoundary)
        return SlideshowFittedText(
            displayText: truncated, fontSize: minimumFontSize, isTruncated: true)
    }

    private static func trialSizes(preferred: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard preferred > minimum else { return [minimum] }
        var sizes: [CGFloat] = []
        var size = preferred
        while size > minimum {
            sizes.append(size)
            size -= shrinkStep
        }
        sizes.append(minimum)  // always probe the exact floor last
        return sizes
    }

    // MARK: - Truncation

    private static func truncate(
        _ text: String, rect: CGRect, fontSize: CGFloat,
        maxLines: Int, boundary: SlideshowTextTruncationBoundary
    ) -> String {
        switch boundary {
        case .composedCharacter:
            return composedCharacterTruncation(
                text, rect: rect, fontSize: fontSize, maxLines: maxLines)
        case .word:
            return wordTruncation(
                text, rect: rect, fontSize: fontSize, maxLines: maxLines)
        }
    }

    /// Largest composed-character (grapheme) prefix of `text` such that
    /// `prefix + …` fits. Monotonic in prefix length, so a binary search finds
    /// the greatest fitting prefix.
    private static func composedCharacterTruncation(
        _ text: String, rect: CGRect, fontSize: CGFloat, maxLines: Int
    ) -> String {
        let ns = text as NSString
        // UTF-16 offsets at each composed-character boundary: [0, …, ns.length].
        var offsets: [Int] = [0]
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            i = r.location + r.length
            offsets.append(i)
        }

        var low = 0
        var high = offsets.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = ns.substring(to: offsets[mid]) + ellipsis
            if fits(
                candidate, fontName: regularFontName, fontSize: fontSize,
                rect: rect, maxLines: maxLines)
            {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return ns.substring(to: offsets[best]) + ellipsis
    }

    /// Largest whole-word prefix of `text` such that `prefix + …` fits. If not
    /// even the first word fits (an over-wide single token), fall back to
    /// composed-character ellipsizing so the token stays representable.
    private static func wordTruncation(
        _ text: String, rect: CGRect, fontSize: CGFloat, maxLines: Int
    ) -> String {
        let ranges = WordTokenizer.wordRanges(in: text)
        guard !ranges.isEmpty else {
            return composedCharacterTruncation(
                text, rect: rect, fontSize: fontSize, maxLines: maxLines)
        }

        func prefix(wordCount m: Int) -> String {
            String(text[text.startIndex..<ranges[m - 1].upperBound])
        }

        var low = 1
        var high = ranges.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = prefix(wordCount: mid) + ellipsis
            if fits(
                candidate, fontName: regularFontName, fontSize: fontSize,
                rect: rect, maxLines: maxLines)
            {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard best > 0 else {
            // Even one word is wider than the content: cut inside the token.
            return composedCharacterTruncation(
                text, rect: rect, fontSize: fontSize, maxLines: maxLines)
        }
        return prefix(wordCount: best) + ellipsis
    }

    // MARK: - karaokePages

    /// Divide `text` into stable, word-aligned pages that each fit `maxLines`
    /// lines of `fontSize` in `rect`, measured with conservative bold metrics and
    /// reserving the width of any required leading/trailing `…`. Pages partition
    /// the source words in order; every source word appears on exactly one page.
    /// The output depends only on `(text, rect, fontSize, maximumLineCount)` — it
    /// takes no active-word index, so page membership can never shift under the
    /// karaoke highlight.
    static func karaokePages(
        for text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        maximumLineCount: Int
    ) -> [SlideshowKaraokePage] {
        let ranges = WordTokenizer.wordRanges(in: text)
        let wordCount = ranges.count
        guard wordCount > 0 else { return [] }
        let words = ranges.map { String(text[$0]) }

        var pages: [SlideshowKaraokePage] = []
        var start = 0
        while start < wordCount {
            // At least one word per page guarantees progress even for an
            // over-wide token; then grow while the next word still fits.
            var end = start + 1
            while end < wordCount {
                let candidateEnd = end + 1
                let candidate = compose(
                    words: words, start: start, end: candidateEnd,
                    totalWords: wordCount)
                if fits(
                    candidate.text, fontName: boldFontName, fontSize: fontSize,
                    rect: rect, maxLines: maximumLineCount)
                {
                    end = candidateEnd
                } else {
                    break
                }
            }
            let page = compose(
                words: words, start: start, end: end, totalWords: wordCount)
            pages.append(
                SlideshowKaraokePage(
                    displayText: page.text, sourceWordRange: start..<end,
                    displayedWords: page.displayedWords))
            start = end
        }
        return pages
    }

    /// Build the display string for source words `[start, end)`, prefixing a
    /// leading `…` when earlier words exist and suffixing a trailing `…` when
    /// later words follow, and record each word's `NSRange` within it.
    private static func compose(
        words: [String], start: Int, end: Int, totalWords: Int
    ) -> (text: String, displayedWords: [SlideshowDisplayedWord]) {
        let hasLeading = start > 0
        let hasTrailing = end < totalWords

        var text = hasLeading ? ellipsis + " " : ""
        var displayed: [SlideshowDisplayedWord] = []
        displayed.reserveCapacity(end - start)
        for w in start..<end {
            if w > start { text += " " }
            let location = (text as NSString).length
            let word = words[w]
            text += word
            let length = (word as NSString).length
            displayed.append(
                SlideshowDisplayedWord(
                    sourceIndex: w,
                    displayRange: NSRange(location: location, length: length)))
        }
        if hasTrailing { text += " " + ellipsis }
        return (text, displayed)
    }

    // MARK: - CoreText measurement

    /// Whether `text` fits within `rect` at `fontSize` in at most `maxLines`
    /// lines. "Fits" = line count ≤ `maxLines` AND suggested height ≤ height AND
    /// widest laid-out line ≤ width. The last clause is what catches an
    /// unbreakable token wider than the content, which the framesetter would
    /// otherwise report as a single (clipped) line.
    private static func fits(
        _ text: String, fontName: String, fontSize: CGFloat,
        rect: CGRect, maxLines: Int
    ) -> Bool {
        guard !text.isEmpty else { return true }
        guard rect.width > 0, rect.height > 0 else { return false }
        let m = measure(
            attributed(text, fontName: fontName, fontSize: fontSize), width: rect.width)
        return m.lineCount <= maxLines
            && m.height <= rect.height + epsilon
            && m.maxLineWidth <= rect.width + epsilon
    }

    private static func attributed(
        _ text: String, fontName: String, fontSize: CGFloat
    ) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        return NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    }

    private static func measure(
        _ attributed: NSAttributedString, width: CGFloat
    ) -> (lineCount: Int, height: CGFloat, maxLineWidth: CGFloat) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let range = CFRange(location: 0, length: attributed.length)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, range, nil,
            CGSize(width: width, height: measurementHeight), &fitRange)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: measurementHeight),
            transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        var maxLineWidth: CGFloat = 0
        for i in 0..<count {
            let line = unsafeBitCast(
                CFArrayGetValueAtIndex(lines, i), to: CTLine.self)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            maxLineWidth = max(maxLineWidth, w)
        }
        return (count, suggested.height, maxLineWidth)
    }
}
