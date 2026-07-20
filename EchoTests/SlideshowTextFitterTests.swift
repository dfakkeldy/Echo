// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import Echo

/// Behavioral tests for the pure CoreText fitter + karaoke pager consumed by the
/// slideshow renderer (Task 5). Assertions favor invariants (line counts,
/// truncation flags, ellipsis presence, word-coverage partition, page-count
/// stability) over brittle exact-pixel widths that could drift across OS
/// versions. Where a concrete `fontSize` is asserted, the rect/text is
/// constructed so the outcome is unambiguous.
struct SlideshowTextFitterTests {

    // Font names must match the renderer (SlideshowFrameRenderer) exactly so the
    // measurements this fitter makes describe the glyphs Task 5 will draw.
    private static let regularFont = "HelveticaNeue"
    private static let boldFont = "HelveticaNeue-Bold"
    private static let ellipsis = "\u{2026}"

    /// Independent CoreText re-measurement used to confirm a produced string fits
    /// (line count and widest line) with a given font — mirrors, but does not
    /// share code with, the implementation under test.
    private func measure(
        _ text: String, font: String, fontSize: CGFloat, width: CGFloat
    ) -> (lineCount: Int, maxLineWidth: CGFloat, height: CGFloat) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName(font as CFString, fontSize, nil)
            ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let range = CFRange(location: 0, length: attributed.length)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, range, nil, CGSize(width: width, height: 100_000), &fitRange)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
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
        return (count, maxLineWidth, suggested.height)
    }

    // MARK: - fit(...)

    @Test func preferredSizeUsedWhenTextFits() {
        let result = SlideshowTextFitter.fit(
            "Hi", in: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            preferredFontSize: 40, minimumFontSize: 20, maximumLineCount: 4,
            truncationBoundary: .composedCharacter)
        #expect(result.displayText == "Hi")
        #expect(result.isTruncated == false)
        #expect(result.fontSize == 40)
    }

    @Test func shrinksInHalfPixelStepsToGreatestFittingSize() {
        // A single-line constraint (maxLines 1) with a tall rect so height never
        // binds: the phrase overflows one line at 60pt but comfortably fits one
        // line once shrunk, and a fitting size exists well above the 10pt floor.
        let preferred: CGFloat = 60
        let minimum: CGFloat = 10
        let result = SlideshowTextFitter.fit(
            "Hello brave new world",
            in: CGRect(x: 0, y: 0, width: 300, height: 4000),
            preferredFontSize: preferred, minimumFontSize: minimum,
            maximumLineCount: 1, truncationBoundary: .word)
        #expect(result.isTruncated == false)
        #expect(result.displayText == "Hello brave new world")
        #expect(result.fontSize < preferred)  // an actual shrink happened
        #expect(result.fontSize >= minimum)
        // Chosen size is preferred - k*0.5 for a nonnegative integer k.
        let dropped = preferred - result.fontSize
        #expect(dropped >= 0)
        #expect(dropped.truncatingRemainder(dividingBy: 0.5) == 0)
        // And the produced size really does fit on one line.
        let m = measure(
            result.displayText, font: Self.regularFont,
            fontSize: result.fontSize, width: 300)
        #expect(m.lineCount <= 1)
    }

    @Test func captionTruncatesAtComposedCharacterWithEllipsis() {
        let text =
            "This is an extremely long caption that absolutely cannot fit "
            + "within the tiny rectangle at any permitted font size whatsoever"
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let result = SlideshowTextFitter.fit(
            text, in: rect, preferredFontSize: 30, minimumFontSize: 20,
            maximumLineCount: 1, truncationBoundary: .composedCharacter)
        #expect(result.isTruncated == true)
        #expect(result.displayText.hasSuffix(Self.ellipsis))
        #expect(result.displayText != text)
        #expect(result.fontSize == 20)  // truncation happens at the minimum size
        // Source is never mutated; the shown text is a prefix + ellipsis.
        let shown = String(result.displayText.dropLast())
        #expect(text.hasPrefix(shown))
        // The ellipsized result actually fits the one-line limit.
        let m = measure(
            result.displayText, font: Self.regularFont, fontSize: 20, width: rect.width)
        #expect(m.lineCount <= 1)
        #expect(m.maxLineWidth <= rect.width + 1)
    }

    @Test func simpleSubtitleTruncatesAtWordBoundary() {
        let text =
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        let rect = CGRect(x: 0, y: 0, width: 150, height: 40)
        let result = SlideshowTextFitter.fit(
            text, in: rect, preferredFontSize: 30, minimumFontSize: 20,
            maximumLineCount: 1, truncationBoundary: .word)
        #expect(result.isTruncated == true)
        #expect(result.displayText.hasSuffix(Self.ellipsis))
        let shown = String(result.displayText.dropLast())
        #expect(!shown.isEmpty)
        #expect(text.hasPrefix(shown))
        // The cut lands on a word boundary: the character following the shown
        // prefix in the source is whitespace (not mid-word).
        let afterIndex = text.index(text.startIndex, offsetBy: shown.count)
        #expect(afterIndex < text.endIndex)
        #expect(text[afterIndex].isWhitespace)
    }

    @Test func overWideSingleTokenFallsBackToComposedCharacter() {
        // One unbreakable token far wider than the content width: word-boundary
        // truncation cannot help, so it falls back to composed-character
        // ellipsizing (a mid-token cut) while staying representable.
        let token = String(repeating: "W", count: 60)
        let rect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let result = SlideshowTextFitter.fit(
            token, in: rect, preferredFontSize: 30, minimumFontSize: 20,
            maximumLineCount: 1, truncationBoundary: .word)
        #expect(result.isTruncated == true)
        #expect(result.displayText.hasSuffix(Self.ellipsis))
        #expect(result.displayText != token)
        let shown = String(result.displayText.dropLast())
        #expect(token.hasPrefix(shown))  // proper prefix of the token
        #expect(shown.count < token.count)
        let m = measure(
            result.displayText, font: Self.regularFont, fontSize: 20, width: rect.width)
        #expect(m.lineCount <= 1)
        #expect(m.maxLineWidth <= rect.width + 1)
    }

    // MARK: - karaokePages(...)

    /// A 30-word subtitle forced into several pages by a small band.
    private func paginated() -> (text: String, pages: [SlideshowKaraokePage], wordCount: Int) {
        let words = (0..<30).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let pages = SlideshowTextFitter.karaokePages(
            for: text, in: CGRect(x: 0, y: 0, width: 220, height: 80),
            fontSize: 22, maximumLineCount: 2)
        return (text, pages, words.count)
    }

    @Test func everySourceWordAppearsOnExactlyOnePage() {
        let (_, pages, wordCount) = paginated()
        #expect(pages.count >= 2)  // the construction actually paginates
        // Ranges partition 0..<wordCount contiguously, in order, no gaps/overlaps.
        #expect(pages.first?.sourceWordRange.lowerBound == 0)
        #expect(pages.last?.sourceWordRange.upperBound == wordCount)
        for (index, page) in pages.enumerated() {
            #expect(page.sourceWordRange.lowerBound < page.sourceWordRange.upperBound)
            if index + 1 < pages.count {
                #expect(
                    page.sourceWordRange.upperBound
                        == pages[index + 1].sourceWordRange.lowerBound)
            }
            // displayedWords enumerate exactly the page's source indices, in order.
            #expect(page.displayedWords.map(\.sourceIndex) == Array(page.sourceWordRange))
        }
    }

    @Test func displayedWordRangesLocateWordsWithinTheirPageText() {
        let (text, pages, _) = paginated()
        let sourceWords = WordTokenizer.words(in: text).map(String.init)
        for page in pages {
            let ns = page.displayText as NSString
            for displayed in page.displayedWords {
                let slice = ns.substring(with: displayed.displayRange)
                #expect(slice == sourceWords[displayed.sourceIndex])
            }
        }
    }

    @Test func leadingAndTrailingEllipsesAppearOnlyWhereTextIsElided() {
        let (_, pages, _) = paginated()
        #expect(pages.count >= 3)  // guarantees a genuine middle page
        for (index, page) in pages.enumerated() {
            let hasLeading = page.displayText.hasPrefix(Self.ellipsis)
            let hasTrailing = page.displayText.hasSuffix(Self.ellipsis)
            // Leading ellipsis exactly when earlier words precede the page.
            #expect(hasLeading == (index > 0))
            // Trailing ellipsis exactly when later words follow the page.
            #expect(hasTrailing == (index < pages.count - 1))
        }
        // Explicit first/last checks per the spec wording.
        #expect(pages.first?.displayText.hasPrefix(Self.ellipsis) == false)
        #expect(pages.last?.displayText.hasSuffix(Self.ellipsis) == false)
    }

    @Test func pagesAreFormedWithConservativeBoldMetrics() {
        // Every produced page must fit the line limit and width when measured
        // with the BOLD font (the conservative "treat every token as bold"
        // metric). Applying real per-word styling can only make lines narrower.
        let (_, pages, _) = paginated()
        let width: CGFloat = 220
        for page in pages {
            let m = measure(
                page.displayText, font: Self.boldFont, fontSize: 22, width: width)
            #expect(m.lineCount <= 2)
            #expect(m.maxLineWidth <= width + 1)
        }
    }

    @Test func pageMembershipIsStableAndIndependentOfActiveWord() {
        // karaokePages has no active-index parameter, so its output depends only
        // on (text, rect, fontSize, lineLimit). Two calls with identical inputs
        // must be byte-for-byte identical, no matter which word is "active"
        // downstream — page membership can never shift under the highlight.
        let text = (0..<30).map { "word\($0)" }.joined(separator: " ")
        let rect = CGRect(x: 0, y: 0, width: 220, height: 80)
        let first = SlideshowTextFitter.karaokePages(
            for: text, in: rect, fontSize: 22, maximumLineCount: 2)
        let second = SlideshowTextFitter.karaokePages(
            for: text, in: rect, fontSize: 22, maximumLineCount: 2)
        #expect(first == second)
    }

    @Test func fittingSubtitleYieldsOneUnadornedPage() {
        let text = "short subtitle"
        let pages = SlideshowTextFitter.karaokePages(
            for: text, in: CGRect(x: 0, y: 0, width: 2000, height: 400),
            fontSize: 22, maximumLineCount: 4)
        #expect(pages.count == 1)
        #expect(pages.first?.sourceWordRange == 0..<2)
        #expect(pages.first?.displayText.contains(Self.ellipsis) == false)
    }

    @Test func emptySubtitleProducesNoPages() {
        let pages = SlideshowTextFitter.karaokePages(
            for: "   ", in: CGRect(x: 0, y: 0, width: 200, height: 80),
            fontSize: 22, maximumLineCount: 2)
        #expect(pages.isEmpty)
    }
}
