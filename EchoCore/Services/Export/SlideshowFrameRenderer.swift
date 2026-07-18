// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Rasterizes one `SlideshowFramePlan` into a `CGImage` matching the Visual
/// Listening stage's structure: dark background, aspect-fit figure (cover art
/// when the plan has no figure), caption beneath it, subtitle band at the
/// bottom with heard-wash / active-word emphasis.
///
/// CoreGraphics/CoreText only — compiles for iOS, macOS, and echo-cli.
/// Performance contract: the composed base (background + figure + caption) is
/// cached per (imagePath, caption) pair; only the subtitle band is redrawn per
/// frame, which is what keeps ~160k-frame karaoke renders tractable.
nonisolated final class SlideshowFrameRenderer {
    private struct BaseKey: Equatable {
        let imagePath: String?
        let caption: String?
    }

    private let width: Int
    private let height: Int
    private let coverArt: CGImage?
    private var cachedBase: (key: BaseKey, image: CGImage)?

    init(width: Int, height: Int, coverArt: CGImage?) {
        self.width = width
        self.height = height
        self.coverArt = coverArt
    }

    func render(_ frame: SlideshowFramePlan) -> CGImage? {
        guard let context = makeContext() else { return nil }
        let baseKey = BaseKey(imagePath: frame.imagePath, caption: frame.caption)
        let base: CGImage?
        if let cachedBase, cachedBase.key == baseKey {
            base = cachedBase.image
        } else {
            base = renderBase(imagePath: frame.imagePath, caption: frame.caption)
            if let base { cachedBase = (key: baseKey, image: base) }
        }
        if let base {
            context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        drawSubtitle(frame, in: context)
        return context.makeImage()
    }

    // MARK: - Base layer

    private func makeContext() -> CGContext? {
        guard width > 0, height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func renderBase(imagePath: String?, caption: String?) -> CGImage? {
        guard let context = makeContext() else { return nil }
        context.setFillColor(CGColor(red: 0.063, green: 0.063, blue: 0.078, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let figure = imagePath.flatMap(Self.loadImage(storedPath:)) ?? coverArt
        // Figure area: horizontally centered, between the caption band and the
        // top margin. Subtitle band ≈ bottom 18%, caption band ≈ next 8%.
        let margin = CGFloat(height) * 0.05
        let figureRect = CGRect(
            x: margin, y: CGFloat(height) * 0.26 + margin,
            width: CGFloat(width) - margin * 2,
            height: CGFloat(height) * 0.74 - margin * 2)
        if let figure {
            context.draw(figure, in: Self.aspectFit(size: figure, into: figureRect))
        }
        if let caption, !caption.isEmpty {
            Self.drawText(
                caption, in: context,
                rect: CGRect(
                    x: margin, y: CGFloat(height) * 0.18,
                    width: CGFloat(width) - margin * 2, height: CGFloat(height) * 0.08),
                fontSize: CGFloat(height) * 0.024, weightBold: false,
                color: CGColor(gray: 1, alpha: 0.7), centered: true)
        }
        return context.makeImage()
    }

    private static func loadImage(storedPath: String) -> CGImage? {
        guard let url = VisualListeningImageLocator.resolvedURL(forStoredPath: storedPath),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
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

    // MARK: - Subtitle band

    private func drawSubtitle(_ frame: SlideshowFramePlan, in context: CGContext) {
        guard let text = frame.subtitleText, !text.isEmpty else { return }
        let margin = CGFloat(height) * 0.05
        let band = CGRect(
            x: margin, y: margin,
            width: CGFloat(width) - margin * 2, height: CGFloat(height) * 0.18 - margin)
        let fontSize = CGFloat(height) * 0.030
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                fontKey: CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil),
                colorKey: CGColor(gray: 1, alpha: 0.38),
            ])
        let bold = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let ranges = WordTokenizer.wordRanges(in: text)
        for (index, range) in ranges.enumerated() {
            let nsRange = NSRange(range, in: text)
            if index < frame.alreadyHeardWordCount {
                attributed.addAttribute(
                    colorKey, value: CGColor(gray: 1, alpha: 0.65), range: nsRange)
            }
            if index == frame.activeWordIndex {
                attributed.addAttributes(
                    [fontKey: bold, colorKey: CGColor(gray: 1, alpha: 1)],
                    range: nsRange)
            }
        }
        Self.draw(attributed, in: context, rect: band, centered: true)
    }

    // MARK: - CoreText plumbing

    private static func drawText(
        _ text: String, in context: CGContext, rect: CGRect,
        fontSize: CGFloat, weightBold: Bool, color: CGColor, centered: Bool
    ) {
        let fontName = weightBold ? "HelveticaNeue-Bold" : "HelveticaNeue"
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
