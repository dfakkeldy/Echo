// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Testing

@testable import Echo

/// Pure-value tests for `SlideshowFrameLayout`. Every fractional geometry
/// comparison uses a `< 0.000_1` tolerance because the layout is deliberately
/// left as unrounded fractional CoreGraphics geometry (the renderer, not this
/// value, decides pixel snapping).
struct SlideshowFrameLayoutTests {
    private let tolerance: CGFloat = 0.000_1

    // MARK: - Assertion helpers

    private func expectClose(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(actual - expected) < tolerance,
            "\(label): expected \(expected), got \(actual)",
            sourceLocation: sourceLocation)
    }

    private func expectRect(
        _ actual: CGRect,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectClose(actual.origin.x, x, "\(label).x", sourceLocation: sourceLocation)
        expectClose(actual.origin.y, y, "\(label).y", sourceLocation: sourceLocation)
        expectClose(actual.size.width, width, "\(label).width", sourceLocation: sourceLocation)
        expectClose(actual.size.height, height, "\(label).height", sourceLocation: sourceLocation)
    }

    // MARK: - Legacy Landscape exact values (1920x1080)

    @Test func legacyLandscapeExactGeometryAt1920x1080() {
        let layout = SlideshowFrameLayout(dimensions: .landscape)

        expectRect(layout.canvasRect, x: 0, y: 0, width: 1920, height: 1080, "canvas")
        expectRect(layout.subtitleRect, x: 54, y: 54, width: 1812, height: 140.4, "subtitle")
        expectRect(layout.captionRect, x: 54, y: 194.4, width: 1812, height: 86.4, "caption")
        expectRect(layout.figureRect, x: 54, y: 334.8, width: 1812, height: 691.2, "figure")

        expectClose(layout.outerInset, 54, "outerInset")
        expectClose(layout.subtitleCaptionGap, 0, "subtitleCaptionGap")
        expectClose(layout.captionFigureGap, 54, "captionFigureGap")
    }

    @Test func legacyLandscapeExactTypographyAt1920x1080() {
        let layout = SlideshowFrameLayout(dimensions: .landscape)

        expectClose(layout.preferredSubtitleFontSize, 32.4, "preferredSubtitle")
        expectClose(layout.minimumSubtitleFontSize, 25.92, "minimumSubtitle")
        expectClose(layout.preferredCaptionFontSize, 25.92, "preferredCaption")
        expectClose(layout.minimumCaptionFontSize, 20.52, "minimumCaption")
        expectClose(layout.preferredCodeFontSize, 28.08, "preferredCode")
        expectClose(layout.minimumCodeFontSize, 21.6, "minimumCode")

        #expect(layout.subtitleLineLimit == 4)
        #expect(layout.captionLineLimit == 3)
    }

    @Test func legacyLandscapeCodeMetricsAt1920x1080() {
        let layout = SlideshowFrameLayout(dimensions: .landscape)

        expectClose(layout.codeContentInset, 27, "codeContentInset")
        expectClose(layout.codeLanguageFontSize, 23.76, "codeLanguageFontSize")
        expectClose(layout.codeLanguageLineHeight, 29.7, "codeLanguageLineHeight")
        expectClose(layout.codeLanguageGap, 13.5, "codeLanguageGap")

        expectRect(
            layout.codeContentRect(hasLanguageLabel: false),
            x: 81, y: 361.8, width: 1758, height: 637.2, "codeContent(noLabel)")
        expectRect(
            layout.codeContentRect(hasLanguageLabel: true),
            x: 81, y: 361.8, width: 1758, height: 594, "codeContent(label)")
        expectRect(
            layout.codeLanguageRect(),
            x: 81, y: 969.3, width: 1758, height: 29.7, "codeLanguage")
    }

    // MARK: - Phone Portrait exact values (1080x1920)

    @Test func phonePortraitExactGeometryAt1080x1920() {
        let layout = SlideshowFrameLayout(dimensions: .portrait)

        expectRect(layout.canvasRect, x: 0, y: 0, width: 1080, height: 1920, "canvas")
        expectRect(layout.subtitleRect, x: 54, y: 54, width: 972, height: 324, "subtitle")
        expectRect(layout.captionRect, x: 54, y: 405, width: 972, height: 151.2, "caption")
        expectRect(layout.figureRect, x: 54, y: 583.2, width: 972, height: 1282.8, "figure")

        expectClose(layout.outerInset, 54, "outerInset")
        expectClose(layout.subtitleCaptionGap, 27, "subtitleCaptionGap")
        expectClose(layout.captionFigureGap, 27, "captionFigureGap")
    }

    @Test func phonePortraitExactTypographyAt1080x1920() {
        let layout = SlideshowFrameLayout(dimensions: .portrait)

        expectClose(layout.preferredSubtitleFontSize, 48.6, "preferredSubtitle")
        expectClose(layout.minimumSubtitleFontSize, 38.88, "minimumSubtitle")
        expectClose(layout.preferredCaptionFontSize, 36.72, "preferredCaption")
        expectClose(layout.minimumCaptionFontSize, 30.24, "minimumCaption")
        expectClose(layout.preferredCodeFontSize, 32.4, "preferredCode")
        expectClose(layout.minimumCodeFontSize, 28.08, "minimumCode")

        #expect(layout.subtitleLineLimit == 4)
        #expect(layout.captionLineLimit == 3)
    }

    @Test func phonePortraitCodeMetricsAt1080x1920() {
        let layout = SlideshowFrameLayout(dimensions: .portrait)

        expectClose(layout.codeContentInset, 27, "codeContentInset")
        expectClose(layout.codeLanguageFontSize, 23.76, "codeLanguageFontSize")
        expectClose(layout.codeLanguageLineHeight, 29.7, "codeLanguageLineHeight")
        expectClose(layout.codeLanguageGap, 13.5, "codeLanguageGap")

        expectRect(
            layout.codeContentRect(hasLanguageLabel: false),
            x: 81, y: 610.2, width: 918, height: 1228.8, "codeContent(noLabel)")
        expectRect(
            layout.codeContentRect(hasLanguageLabel: true),
            x: 81, y: 610.2, width: 918, height: 1185.6, "codeContent(label)")
        expectRect(
            layout.codeLanguageRect(),
            x: 81, y: 1809.3, width: 918, height: 29.7, "codeLanguage")
    }

    // MARK: - Invariant matrix over boundary and representative sizes

    @Test func layoutInvariantsHoldAcrossValidSizes() throws {
        let sizes: [(width: Int, height: Int)] = [
            (320, 180),
            (640, 360),
            (1920, 1080),
            (1080, 1920),
            (3840, 2160),
            (2160, 3840),
            (720, 720),
        ]

        for size in sizes {
            let label = "\(size.width)x\(size.height)"
            let dimensions = try SlideshowVideoDimensions.validating(
                width: size.width, height: size.height)
            let layout = SlideshowFrameLayout(dimensions: dimensions)
            let canvas = CGRect(
                x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height))
            let regions = [layout.subtitleRect, layout.captionRect, layout.figureRect]

            // Canvas matches the requested pixel size exactly.
            expectRect(
                layout.canvasRect,
                x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height),
                "canvas \(label)")

            // 1. Every rectangle is finite and non-negative.
            for rect in regions + [layout.canvasRect] {
                #expect(
                    rect.origin.x.isFinite && rect.origin.y.isFinite
                        && rect.size.width.isFinite && rect.size.height.isFinite,
                    "rect must be finite at \(label): \(rect)")
                #expect(
                    rect.origin.x >= 0 && rect.origin.y >= 0
                        && rect.size.width >= 0 && rect.size.height >= 0,
                    "rect must be non-negative at \(label): \(rect)")
            }

            // 2. Every region is contained by the pixel canvas.
            for rect in regions {
                #expect(
                    canvas.contains(rect),
                    "region \(rect) escapes canvas at \(label)")
            }

            // 3. Vertical order bottom-to-top (CG bottom-left): subtitle, caption, figure.
            #expect(
                layout.subtitleRect.maxY <= layout.captionRect.minY + tolerance,
                "subtitle must sit below caption at \(label)")
            #expect(
                layout.captionRect.maxY <= layout.figureRect.minY + tolerance,
                "caption must sit below figure at \(label)")

            // 4. No pairwise intersection with positive area.
            #expect(
                layout.subtitleRect.intersection(layout.captionRect).isEmpty,
                "subtitle/caption overlap at \(label)")
            #expect(
                layout.subtitleRect.intersection(layout.figureRect).isEmpty,
                "subtitle/figure overlap at \(label)")
            #expect(
                layout.captionRect.intersection(layout.figureRect).isEmpty,
                "caption/figure overlap at \(label)")

            // 5. Figure region has positive height.
            #expect(layout.figureRect.height > 0, "figure height must be positive at \(label)")

            // 6. Every preferred font is no smaller than its declared minimum.
            #expect(
                layout.preferredSubtitleFontSize >= layout.minimumSubtitleFontSize,
                "subtitle font ordering at \(label)")
            #expect(
                layout.preferredCaptionFontSize >= layout.minimumCaptionFontSize,
                "caption font ordering at \(label)")
            #expect(
                layout.preferredCodeFontSize >= layout.minimumCodeFontSize,
                "code font ordering at \(label)")
            #expect(
                layout.minimumSubtitleFontSize > 0
                    && layout.minimumCaptionFontSize > 0
                    && layout.minimumCodeFontSize > 0,
                "fonts must be positive at \(label)")
        }
    }

    // MARK: - Profile selection

    @Test func squareResolvesToLegacyLandscapeProfile() throws {
        let square = try SlideshowVideoDimensions.validating(width: 720, height: 720)
        #expect(square.layoutProfile == .legacyLandscape)

        // A square uses the legacy subtitle band ratio (0.13 of the short side),
        // not the much taller portrait band (0.30), so this pins profile choice.
        let layout = SlideshowFrameLayout(dimensions: square)
        expectClose(layout.subtitleRect.height, 720 * 0.13, "square subtitle height")
    }
}
