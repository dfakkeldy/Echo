// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// A pure, calculated layout for one slideshow video frame.
///
/// `SlideshowFrameLayout` is the single source of geometry for the exporter's
/// renderer: given validated `SlideshowVideoDimensions`, it yields the canvas,
/// the subtitle/caption/figure(code) rectangles, the inter-region gaps, and all
/// typography sizes. The renderer no longer invents geometry — it consumes this
/// value verbatim.
///
/// Coordinates use CoreGraphics' bottom-left origin. Vertically, regions stack
/// bottom-to-top as subtitle, caption, then figure/code. Because dimensions are
/// already product-validated (short side ≥ 180, aspect ≤ 4:1, even sizes), the
/// following invariants hold by construction for every accepted size:
///
/// 1. every rectangle is finite and non-negative;
/// 2. every rectangle is contained by the pixel canvas;
/// 3. the three content rectangles never overlap;
/// 4. their bottom-to-top order is subtitle, caption, figure/code;
/// 5. every preferred font is positive and no smaller than its minimum.
///
/// Geometry is intentionally fractional and never rounded here; pixel snapping,
/// if any, is a rendering concern.
///
/// The calculator is driven by a private, value-semantic
/// `SlideshowLayoutSpecification` selected by `layoutProfile`, not by
/// conditionals scattered through the initializer. In v1 there are exactly two
/// specifications (Legacy Landscape and Phone Portrait); the type is the
/// internal upgrade seam for future built-in profiles. It is deliberately not
/// public API, persisted data, or user-editable configuration.
nonisolated struct SlideshowFrameLayout: Equatable, Sendable {
    let canvasRect: CGRect
    let subtitleRect: CGRect
    let captionRect: CGRect
    let figureRect: CGRect
    let outerInset: CGFloat
    let subtitleCaptionGap: CGFloat
    let captionFigureGap: CGFloat
    let preferredCaptionFontSize: CGFloat
    let minimumCaptionFontSize: CGFloat
    let preferredSubtitleFontSize: CGFloat
    let minimumSubtitleFontSize: CGFloat
    let preferredCodeFontSize: CGFloat
    let minimumCodeFontSize: CGFloat
    let captionLineLimit: Int
    let subtitleLineLimit: Int
    let codeContentInset: CGFloat
    let codeLanguageFontSize: CGFloat
    let codeLanguageLineHeight: CGFloat
    let codeLanguageGap: CGFloat

    init(dimensions: SlideshowVideoDimensions) {
        let width = CGFloat(dimensions.width)
        let height = CGFloat(dimensions.height)
        let spec = SlideshowLayoutSpecification.specification(for: dimensions.layoutProfile)

        // Every region/typography ratio for a profile is measured against a
        // single base dimension. Legacy uses canvas height; Phone Portrait uses
        // the short side. Both coincide with `min(W, H)` within their own
        // orientation domain, which is what keeps Legacy algebraically identical
        // to the pre-existing height-only renderer formulas.
        let base = spec.baseDimension.value(width: width, height: height)

        let margin = spec.outerMarginRatio * base
        let contentWidth = width - margin * 2

        // Bottom-to-top stack: subtitle at the bottom margin, caption above it
        // (separated by the subtitle→caption gap), then the figure/code region
        // filling the remaining space up to the top margin (H - margin).
        let subtitle = CGRect(
            x: margin, y: margin,
            width: contentWidth, height: spec.subtitleHeightRatio * base)

        let subtitleCaptionGap = spec.subtitleCaptionGapRatio * base
        let caption = CGRect(
            x: margin, y: subtitle.maxY + subtitleCaptionGap,
            width: contentWidth, height: spec.captionHeightRatio * base)

        let captionFigureGap = spec.captionFigureGapRatio * base
        let figureOriginY = caption.maxY + captionFigureGap
        let figure = CGRect(
            x: margin, y: figureOriginY,
            width: contentWidth, height: (height - margin) - figureOriginY)

        canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        subtitleRect = subtitle
        captionRect = caption
        figureRect = figure

        outerInset = margin
        self.subtitleCaptionGap = subtitleCaptionGap
        self.captionFigureGap = captionFigureGap

        preferredSubtitleFontSize = spec.preferredSubtitleFontRatio * base
        minimumSubtitleFontSize = spec.minimumSubtitleFontRatio * base
        preferredCaptionFontSize = spec.preferredCaptionFontRatio * base
        minimumCaptionFontSize = spec.minimumCaptionFontRatio * base
        preferredCodeFontSize = spec.preferredCodeFontRatio * base
        minimumCodeFontSize = spec.minimumCodeFontRatio * base

        subtitleLineLimit = spec.subtitleLineLimit
        captionLineLimit = spec.captionLineLimit

        // Code-card metrics are derived from the short side for both profiles so
        // padding and label sizing stay perceptually consistent regardless of
        // orientation.
        let shortSide = min(width, height)
        codeContentInset = SlideshowLayoutSpecification.codeContentInsetRatio * shortSide
        codeLanguageFontSize = SlideshowLayoutSpecification.codeLanguageFontRatio * shortSide
        codeLanguageLineHeight =
            SlideshowLayoutSpecification.codeLanguageLineHeightFactor * codeLanguageFontSize
        codeLanguageGap = SlideshowLayoutSpecification.codeLanguageGapRatio * shortSide
    }

    /// The rectangle the code text occupies inside the code card.
    ///
    /// Without a language label it is the figure/code rectangle inset by
    /// `codeContentInset` on every edge. With a label, the label consumes the
    /// top-leading line box (see `codeLanguageRect()`), so the code content
    /// begins below that box plus `codeLanguageGap`. In bottom-left coordinates
    /// "below" means a lower maximum-Y, i.e. the content keeps the padded card's
    /// bottom edge and loses height from the top. Both rectangles stay inside
    /// the padded card.
    func codeContentRect(hasLanguageLabel: Bool) -> CGRect {
        let padded = figureRect.insetBy(dx: codeContentInset, dy: codeContentInset)
        guard hasLanguageLabel else { return padded }
        let reservedTop = codeLanguageLineHeight + codeLanguageGap
        return CGRect(
            x: padded.minX, y: padded.minY,
            width: padded.width, height: padded.height - reservedTop)
    }

    /// The top-leading padded line box reserved for the optional language label,
    /// spanning the card's content width at height `codeLanguageLineHeight`.
    func codeLanguageRect() -> CGRect {
        let padded = figureRect.insetBy(dx: codeContentInset, dy: codeContentInset)
        return CGRect(
            x: padded.minX, y: padded.maxY - codeLanguageLineHeight,
            width: padded.width, height: codeLanguageLineHeight)
    }
}

/// The canvas dimension a `SlideshowLayoutSpecification`'s ratios are measured
/// against. Legacy Landscape historically expressed every fraction in terms of
/// canvas height; Phone Portrait expresses them in terms of the short side.
private nonisolated enum SlideshowLayoutBaseDimension: Sendable {
    case canvasHeight
    case shortestSide

    func value(width: CGFloat, height: CGFloat) -> CGFloat {
        switch self {
        case .canvasHeight: height
        case .shortestSide: min(width, height)
        }
    }
}

/// A value-semantic description of one layout profile: the ratios (relative to
/// its base dimension) that produce the region rectangles, gaps, and typography.
///
/// This is the internal seam the design calls for — pure data, one instance per
/// built-in profile, selected by `SlideshowFrameLayoutProfile`. It is not public
/// API, persisted, or user-editable. Code-card metrics are profile-independent
/// (always derived from the short side) and therefore live as static constants
/// rather than per-profile fields.
private nonisolated struct SlideshowLayoutSpecification: Sendable {
    let baseDimension: SlideshowLayoutBaseDimension
    let outerMarginRatio: CGFloat
    let subtitleHeightRatio: CGFloat
    let subtitleCaptionGapRatio: CGFloat
    let captionHeightRatio: CGFloat
    let captionFigureGapRatio: CGFloat
    let preferredSubtitleFontRatio: CGFloat
    let minimumSubtitleFontRatio: CGFloat
    let preferredCaptionFontRatio: CGFloat
    let minimumCaptionFontRatio: CGFloat
    let preferredCodeFontRatio: CGFloat
    let minimumCodeFontRatio: CGFloat
    let subtitleLineLimit: Int
    let captionLineLimit: Int

    // Code-card metrics, shared by both profiles, as ratios of the short side
    // (except the line-height factor, which multiplies the language font size).
    static let codeContentInsetRatio: CGFloat = 0.025
    static let codeLanguageFontRatio: CGFloat = 0.022
    static let codeLanguageLineHeightFactor: CGFloat = 1.25
    static let codeLanguageGapRatio: CGFloat = 0.012_5

    /// Legacy Landscape. Ratios are of canvas height and are algebraically
    /// identical to the original height-only renderer formulas: subtitle band
    /// `0.18H - M`, caption band `0.08H` at `0.18H`, figure `0.31H`…`0.95H`.
    static let legacyLandscape = SlideshowLayoutSpecification(
        baseDimension: .canvasHeight,
        outerMarginRatio: 0.05,
        subtitleHeightRatio: 0.13,
        subtitleCaptionGapRatio: 0,
        captionHeightRatio: 0.08,
        captionFigureGapRatio: 0.05,
        preferredSubtitleFontRatio: 0.030,
        minimumSubtitleFontRatio: 0.024,
        preferredCaptionFontRatio: 0.024,
        minimumCaptionFontRatio: 0.019,
        preferredCodeFontRatio: 0.026,
        minimumCodeFontRatio: 0.020,
        subtitleLineLimit: 4,
        captionLineLimit: 3)

    /// Phone Portrait. Ratios are of the short side `S = min(W, H)`, with a
    /// `0.025S` gap separating each region.
    static let phonePortrait = SlideshowLayoutSpecification(
        baseDimension: .shortestSide,
        outerMarginRatio: 0.05,
        subtitleHeightRatio: 0.30,
        subtitleCaptionGapRatio: 0.025,
        captionHeightRatio: 0.14,
        captionFigureGapRatio: 0.025,
        preferredSubtitleFontRatio: 0.045,
        minimumSubtitleFontRatio: 0.036,
        preferredCaptionFontRatio: 0.034,
        minimumCaptionFontRatio: 0.028,
        preferredCodeFontRatio: 0.030,
        minimumCodeFontRatio: 0.026,
        subtitleLineLimit: 4,
        captionLineLimit: 3)

    static func specification(
        for profile: SlideshowFrameLayoutProfile
    ) -> SlideshowLayoutSpecification {
        switch profile {
        case .legacyLandscape: legacyLandscape
        case .phonePortrait: phonePortrait
        }
    }
}
