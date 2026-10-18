// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Rasterizes one `SlideshowFramePlan` into a `CGImage` for the Visual Listening
/// slideshow video exporter: dark background, an aspect-fit figure region (image,
/// static code card, or cover-art fallback), a caption band, and a subtitle band
/// with heard-wash / active-word emphasis.
///
/// The renderer no longer invents geometry. It is constructed from validated
/// `SlideshowVideoDimensions` and reads every rectangle, gap, font size, and line
/// limit from a single immutable `SlideshowFrameLayout`, so Legacy Landscape and
/// Phone Portrait share one drawing path selected purely by the layout profile.
/// At 1920x1080 the layout is algebraically identical to the pre-refactor
/// height-only formulas, which the `LegacyLandscapeFrameReferenceRenderer` pixel
/// tests lock in place.
///
/// Text never silently overflows: captions and simple subtitles route through
/// `SlideshowTextFitter.fit`, karaoke subtitles through stable
/// `SlideshowTextFitter.karaokePages`, and code lines are monospaced with explicit
/// per-line and final-row ellipses.
///
/// CoreGraphics/CoreText only — compiles for iOS, macOS, echo-cli, and the Widget
/// (no UIKit/AppKit/SwiftUI).
///
/// Performance contract: the composed base (background + figure/code + caption) is
/// cached per `(visualContent, caption)` pair; only the subtitle band is redrawn
/// per frame, and karaoke pagination is memoized per subtitle, which is what keeps
/// ~160k-frame karaoke renders tractable.
nonisolated final class SlideshowFrameRenderer {
    /// The base image depends only on the visual payload and caption; every other
    /// per-frame difference (subtitle text/emphasis) is drawn on top of it.
    private struct BaseKey: Equatable {
        let visualContent: VisualListeningVisualContent?
        let caption: String?
    }

    /// Karaoke pagination is a pure function of these inputs (rect size, minimum
    /// font, and line limit are renderer-constant, so `text` is the only varying
    /// component in practice). Caching keyed here avoids re-paginating a repeated
    /// subtitle across the hundreds/thousands of frames that share it.
    private struct KaraokeKey: Hashable {
        let text: String
        let width: CGFloat
        let height: CGFloat
        let minimumFontSize: CGFloat
        let lineLimit: Int
    }

    /// A subtitle's paginated karaoke layout: the chosen font size (preferred when
    /// the whole subtitle fits on one page, otherwise the minimum) plus the stable
    /// pages produced at that size.
    private struct KaraokeLayout {
        let fontSize: CGFloat
        let pages: [SlideshowKaraokePage]
    }

    // Font names. Caption/subtitle MUST match `SlideshowTextFitter` so its
    // measurements describe the glyphs that are actually rasterized.
    private static let regularFontName = "HelveticaNeue"
    private static let boldFontName = "HelveticaNeue-Bold"
    private static let codeFontName = "Menlo"
    private static let ellipsis = "\u{2026}"
    /// Line-box multiplier for monospaced code rows (font metrics + breathing room).
    private static let codeLineSpacing: CGFloat = 1.2

    private static let backgroundColor = CGColor(red: 0.063, green: 0.063, blue: 0.078, alpha: 1)
    private static let captionColor = CGColor(gray: 1, alpha: 0.7)
    private static let subtitleColor = CGColor(gray: 1, alpha: 0.38)
    private static let heardColor = CGColor(gray: 1, alpha: 0.65)
    private static let activeColor = CGColor(gray: 1, alpha: 1)
    private static let codeSurfaceColor = CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
    private static let codeTextColor = CGColor(gray: 1, alpha: 0.92)
    private static let codeLanguageColor = CGColor(gray: 1, alpha: 0.5)

    private let dimensions: SlideshowVideoDimensions
    private let layout: SlideshowFrameLayout
    private let coverArt: CGImage?
    private let imageLoader: @Sendable (String) -> CGImage?
    private var cachedBase: (key: BaseKey, image: CGImage)?
    private var karaokeCache: [KaraokeKey: KaraokeLayout] = [:]

    init(
        dimensions: SlideshowVideoDimensions,
        coverArt: CGImage?,
        imageLoader: @escaping @Sendable (String) -> CGImage? = {
            SlideshowFrameRenderer.loadImage(storedPath: $0)
        }
    ) {
        self.dimensions = dimensions
        self.layout = SlideshowFrameLayout(dimensions: dimensions)
        self.coverArt = coverArt
        self.imageLoader = imageLoader
    }

    func render(_ frame: SlideshowFramePlan) -> CGImage? {
        guard let context = makeContext() else { return nil }
        let baseKey = BaseKey(visualContent: frame.visualContent, caption: frame.caption)
        let base: CGImage?
        if let cachedBase, cachedBase.key == baseKey {
            base = cachedBase.image
        } else {
            base = renderBase(visualContent: frame.visualContent, caption: frame.caption)
            if let base { cachedBase = (key: baseKey, image: base) }
        }
        if let base {
            context.draw(base, in: layout.canvasRect)
        }
        drawSubtitle(frame, in: context)
        return context.makeImage()
    }

    // MARK: - Base layer

    private func makeContext() -> CGContext? {
        guard dimensions.width > 0, dimensions.height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGContext(
            data: nil, width: dimensions.width, height: dimensions.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws the cached base: background, then the payload-specific figure/code
    /// region, then the caption (suppressed for code cues so the narration is not
    /// duplicated between caption and subtitle).
    private func renderBase(
        visualContent: VisualListeningVisualContent?, caption: String?
    ) -> CGImage? {
        guard let context = makeContext() else { return nil }
        context.setFillColor(Self.backgroundColor)
        context.fill(layout.canvasRect)

        switch visualContent {
        case .image(let path):
            drawFigureImage(preferredPath: path, in: context)
            drawCaption(caption, in: context)
        case .code(let text, let language):
            drawCodeCard(text: text, language: language, in: context)
        // Caption is intentionally left empty for code cues.
        case nil:
            drawFigureImage(preferredPath: nil, in: context)
            drawCaption(caption, in: context)
        }
        return context.makeImage()
    }

    /// Loads `preferredPath` (falling back to cover art when it is missing or
    /// undecodable, then to the dark region when there is no cover art) and
    /// aspect-fits it uncropped, centered, inside `layout.figureRect`. Because the
    /// fitted rectangle is always contained by `figureRect`, no clipping is needed.
    private func drawFigureImage(preferredPath: String?, in context: CGContext) {
        guard let figure = preferredPath.flatMap(imageLoader) ?? coverArt else { return }
        context.draw(figure, in: Self.aspectFit(size: figure, into: layout.figureRect))
    }

    private func drawCaption(_ caption: String?, in context: CGContext) {
        guard let caption, !caption.isEmpty else { return }
        let fitted = SlideshowTextFitter.fit(
            caption, in: layout.captionRect,
            preferredFontSize: layout.preferredCaptionFontSize,
            minimumFontSize: layout.minimumCaptionFontSize,
            maximumLineCount: layout.captionLineLimit,
            truncationBoundary: .composedCharacter)
        context.saveGState()
        context.clip(to: layout.captionRect)
        Self.drawText(
            fitted.displayText, in: context, rect: layout.captionRect,
            fontSize: fitted.fontSize, weightBold: false,
            color: Self.captionColor, centered: true)
        context.restoreGState()
    }

    private static func loadImage(storedPath: String) -> CGImage? {
        guard let url = VisualListeningImageLocator.resolvedURL(forStoredPath: storedPath),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        guard let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber,
            (2...8).contains(orientation.intValue)
        else { return image }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
    }

    private static func aspectFit(size image: CGImage, into rect: CGRect) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
    }

    // MARK: - Code card

    /// Renders a static code card inside `layout.figureRect`: a restrained lighter
    /// rounded surface, an optional top-leading language label, and monospaced,
    /// top-leading, non-wrapping code with explicit per-line and final-row ellipses.
    private func drawCodeCard(text: String, language: String?, in context: CGContext) {
        let card = layout.figureRect
        guard card.width > 0, card.height > 0 else { return }
        context.saveGState()
        context.clip(to: card)

        let radius = min(layout.codeContentInset, min(card.width, card.height) / 2)
        context.setFillColor(Self.codeSurfaceColor)
        context.addPath(
            CGPath(
                roundedRect: card, cornerWidth: radius, cornerHeight: radius,
                transform: nil))
        context.fillPath()

        let hasLanguageLabel = !(language?.isEmpty ?? true)
        if hasLanguageLabel, let language {
            drawCodeLanguageLabel(language, in: context)
        }
        drawCodeContent(text, hasLanguageLabel: hasLanguageLabel, in: context)

        context.restoreGState()
    }

    private func drawCodeLanguageLabel(_ language: String, in context: CGContext) {
        let rect = layout.codeLanguageRect()
        guard rect.width > 0, rect.height > 0 else { return }
        let font = CTFontCreateWithName(
            Self.codeFontName as CFString, layout.codeLanguageFontSize, nil)
        let baselineY = rect.maxY - CTFontGetAscent(font)
        let display = Self.truncateLine(language, font: font, maxWidth: rect.width)
        Self.drawMonospacedLine(
            display, font: font, color: Self.codeLanguageColor,
            at: CGPoint(x: rect.minX, y: baselineY), in: context)
    }

    private func drawCodeContent(
        _ text: String, hasLanguageLabel: Bool, in context: CGContext
    ) {
        let rect = layout.codeContentRect(hasLanguageLabel: hasLanguageLabel)
        guard rect.width > 0, rect.height > 0 else { return }

        let sourceLines = text.components(separatedBy: "\n")
        let fontSize = chosenCodeFontSize(for: sourceLines, in: rect)
        let font = CTFontCreateWithName(Self.codeFontName as CFString, fontSize, nil)
        let lineHeight = Self.codeLineHeight(for: font)
        guard lineHeight > 0 else { return }
        let maxRows = Int(((rect.height + 0.5) / lineHeight).rounded(.down))
        guard maxRows > 0 else { return }

        // When more source lines exist than fit, the final visible row becomes a
        // standalone ellipsis marker instead of a truncated real line.
        let visibleLines: [String]
        if sourceLines.count <= maxRows {
            visibleLines = sourceLines
        } else {
            visibleLines = Array(sourceLines.prefix(max(0, maxRows - 1))) + [Self.ellipsis]
        }

        var baselineY = rect.maxY - CTFontGetAscent(font)
        for line in visibleLines {
            let display = Self.truncateLine(line, font: font, maxWidth: rect.width)
            Self.drawMonospacedLine(
                display, font: font, color: Self.codeTextColor,
                at: CGPoint(x: rect.minX, y: baselineY), in: context)
            baselineY -= lineHeight
        }
    }

    /// Largest size in `[minimum, preferred]` (0.5-pt steps) at which every source
    /// line fits the content width and all lines fit vertically; the minimum
    /// otherwise (remaining overflow is made explicit with ellipses at draw time).
    private func chosenCodeFontSize(for lines: [String], in rect: CGRect) -> CGFloat {
        let preferred = layout.preferredCodeFontSize
        let minimum = layout.minimumCodeFontSize
        guard preferred > minimum else { return minimum }
        var size = preferred
        while size > minimum {
            if Self.codeFits(lines, in: rect, fontSize: size) { return size }
            size -= 0.5
        }
        return minimum
    }

    private static func codeFits(
        _ lines: [String], in rect: CGRect, fontSize: CGFloat
    ) -> Bool {
        let font = CTFontCreateWithName(codeFontName as CFString, fontSize, nil)
        let lineHeight = codeLineHeight(for: font)
        guard lineHeight > 0 else { return false }
        if CGFloat(lines.count) * lineHeight > rect.height + 0.5 { return false }
        for line in lines where lineWidth(line, font: font) > rect.width + 0.5 {
            return false
        }
        return true
    }

    private static func codeLineHeight(for font: CTFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return (ascent + descent + leading) * codeLineSpacing
    }

    private static func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(
            CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    /// Largest composed-character prefix of `text` whose `prefix + …` fits
    /// `maxWidth`; the full `text` unchanged when it already fits.
    private static func truncateLine(
        _ text: String, font: CTFont, maxWidth: CGFloat
    ) -> String {
        guard maxWidth > 0 else { return "" }
        if lineWidth(text, font: font) <= maxWidth + 0.5 { return text }
        let chars = Array(text)
        var low = 0
        var high = chars.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(chars.prefix(mid)) + ellipsis
            if lineWidth(candidate, font: font) <= maxWidth + 0.5 {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return String(chars.prefix(best)) + ellipsis
    }

    private static func drawMonospacedLine(
        _ text: String, font: CTFont, color: CGColor, at point: CGPoint,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.restoreGState()
    }

    // MARK: - Subtitle band

    private func drawSubtitle(_ frame: SlideshowFramePlan, in context: CGContext) {
        guard let text = frame.subtitleText, !text.isEmpty else { return }
        let rect = layout.subtitleRect

        // Karaoke: only when the frame carries a valid active word that lands on a
        // page. Otherwise fall back to Simple fitting for this frame.
        if let active = frame.activeWordIndex {
            let karaoke = karaokeLayout(for: text)
            if let page = karaoke.pages.first(where: { $0.sourceWordRange.contains(active) }) {
                drawKaraokePage(
                    page, fontSize: karaoke.fontSize, activeWordIndex: active,
                    heardCount: frame.alreadyHeardWordCount, in: rect, context: context)
                return
            }
        }
        drawSimpleSubtitle(text, in: rect, context: context)
    }

    private func drawSimpleSubtitle(_ text: String, in rect: CGRect, context: CGContext) {
        let fitted = SlideshowTextFitter.fit(
            text, in: rect,
            preferredFontSize: layout.preferredSubtitleFontSize,
            minimumFontSize: layout.minimumSubtitleFontSize,
            maximumLineCount: layout.subtitleLineLimit,
            truncationBoundary: .word)
        context.saveGState()
        context.clip(to: rect)
        Self.drawText(
            fitted.displayText, in: context, rect: rect, fontSize: fitted.fontSize,
            weightBold: false, color: Self.subtitleColor, centered: true)
        context.restoreGState()
    }

    /// Applies heard-wash and active-word emphasis to a stable karaoke page. Only
    /// the page's `SlideshowDisplayedWord` mappings are used to locate words, so
    /// the page's `displayText` (which may carry a leading `…`) is never
    /// re-tokenized and per-word styling can never shift page membership.
    private func drawKaraokePage(
        _ page: SlideshowKaraokePage, fontSize: CGFloat, activeWordIndex: Int,
        heardCount: Int, in rect: CGRect, context: CGContext
    ) {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attributed = NSMutableAttributedString(
            string: page.displayText,
            attributes: [
                fontKey: CTFontCreateWithName(Self.regularFontName as CFString, fontSize, nil),
                colorKey: Self.subtitleColor,
            ])
        let bold = CTFontCreateWithName(Self.boldFontName as CFString, fontSize, nil)
        for word in page.displayedWords {
            if word.sourceIndex < heardCount {
                attributed.addAttribute(colorKey, value: Self.heardColor, range: word.displayRange)
            }
            if word.sourceIndex == activeWordIndex {
                attributed.addAttributes(
                    [fontKey: bold, colorKey: Self.activeColor], range: word.displayRange)
            }
        }
        context.saveGState()
        context.clip(to: rect)
        Self.draw(attributed, in: context, rect: rect, centered: true)
        context.restoreGState()
    }

    /// Returns the memoized karaoke pagination for `text`. Pages fit at the
    /// preferred subtitle size when the whole subtitle lands on a single page;
    /// otherwise they are paginated at the minimum subtitle size (no less than the
    /// profile minimum). The result is independent of the active word.
    private func karaokeLayout(for text: String) -> KaraokeLayout {
        let key = KaraokeKey(
            text: text, width: layout.subtitleRect.width, height: layout.subtitleRect.height,
            minimumFontSize: layout.minimumSubtitleFontSize, lineLimit: layout.subtitleLineLimit)
        if let cached = karaokeCache[key] { return cached }

        let atPreferred = SlideshowTextFitter.karaokePages(
            for: text, in: layout.subtitleRect,
            fontSize: layout.preferredSubtitleFontSize,
            maximumLineCount: layout.subtitleLineLimit)
        let result: KaraokeLayout
        if atPreferred.count <= 1 {
            result = KaraokeLayout(fontSize: layout.preferredSubtitleFontSize, pages: atPreferred)
        } else {
            let atMinimum = SlideshowTextFitter.karaokePages(
                for: text, in: layout.subtitleRect,
                fontSize: layout.minimumSubtitleFontSize,
                maximumLineCount: layout.subtitleLineLimit)
            result = KaraokeLayout(fontSize: layout.minimumSubtitleFontSize, pages: atMinimum)
        }
        karaokeCache[key] = result
        return result
    }

    // MARK: - CoreText plumbing

    private static func drawText(
        _ text: String, in context: CGContext, rect: CGRect,
        fontSize: CGFloat, weightBold: Bool, color: CGColor, centered: Bool
    ) {
        let fontName = weightBold ? boldFontName : regularFontName
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName(fontName as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
        draw(attributed, in: context, rect: rect, centered: centered)
    }

    private static func draw(
        _ attributed: NSAttributedString, in context: CGContext,
        rect: CGRect, centered: Bool
    ) {
        let styled = NSMutableAttributedString(attributedString: attributed)
        if centered {
            var alignment = CTTextAlignment.center
            let paragraph = withUnsafePointer(to: &alignment) { pointer in
                var setting = CTParagraphStyleSetting(
                    spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            styled.addAttribute(
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
                value: paragraph, range: NSRange(location: 0, length: styled.length))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(styled)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: styled.length), path, nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
