// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

#if canImport(UIKit)
    import UIKit
#endif

/// Renders square thumbnails that **preserve** a cover's aspect ratio: the whole
/// cover is aspect-fit and centred, and the empty margins are filled with an
/// artwork-derived background (the cover's average colour as a tonal base, plus a
/// soft blurred wash of the cover) so portrait/landscape covers still look
/// intentional in Echo's square audiobook surfaces (Now Playing, lock screen,
/// Watch, widget). The readable cover is never stretched or cropped.
///
/// Shared by `ArtworkCache` for both the display (300pt) and Watch (200pt)
/// thumbnails so there is a single, testable aspect-preserving code path.
///
/// `nonisolated`: pure image/geometry maths whose inputs are used synchronously
/// and never escape, so — like `DominantColorExtractor` — it must opt out of the
/// project's default `@MainActor` isolation to stay callable from any context
/// (and from the nonisolated tests). The `CoreGraphics`-only geometry surface
/// compiles on every target; the `UIKit` rendering is gated to platforms that
/// have `UIGraphicsImageRenderer`.
nonisolated enum ThumbnailRenderer {

    // MARK: - Geometry (all platforms)

    /// The rect that aspect-**fits** `sourceSize`, centred, inside `canvasSize`.
    /// Preserves the source aspect ratio (never stretches) and centres the fitted
    /// rect within the canvas. Returns `.zero` for non-positive inputs.
    static func aspectFitRect(sourceSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
            canvasSize.width > 0, canvasSize.height > 0
        else { return .zero }
        let scale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let fitted = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (canvasSize.width - fitted.width) / 2,
            y: (canvasSize.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    /// The rect that aspect-**fills** `canvasSize` with `sourceSize`, centred
    /// (overflow extends past the canvas edges). Preserves the source aspect
    /// ratio. Used for the decorative background wash. Returns `.zero` for
    /// non-positive inputs.
    static func aspectFillRect(sourceSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
            canvasSize.width > 0, canvasSize.height > 0
        else { return .zero }
        let scale = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let filled = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (canvasSize.width - filled.width) / 2,
            y: (canvasSize.height - filled.height) / 2,
            width: filled.width, height: filled.height)
    }

    #if canImport(UIKit)

        // MARK: - Rendering (UIKit)

        /// The mean colour of `image`, used as the opaque tonal base behind the
        /// blurred wash. Deterministic. Falls back to a neutral graphite if the
        /// pixels cannot be read.
        static func averageColor(of image: UIImage) -> UIColor {
            let fallback = UIColor(white: 0.12, alpha: 1)
            guard let cgImage = image.cgImage else { return fallback }
            var pixel: [UInt8] = [0, 0, 0, 0]
            // `noneSkipLast` (RGBX) reads straight, non-premultiplied RGB so a
            // 1×1 area-average is the true mean colour regardless of source alpha.
            guard
                let context = CGContext(
                    data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return fallback }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return UIColor(
                red: CGFloat(pixel[0]) / 255,
                green: CGFloat(pixel[1]) / 255,
                blue: CGFloat(pixel[2]) / 255,
                alpha: 1)
        }

        /// Renders `source` aspect-fit + centred into a `side`×`side` canvas at
        /// `scale`, filling the letterbox/pillarbox margins with the
        /// artwork-derived background. The output is always opaque and exactly
        /// `side`×`side` points. The readable cover is never stretched or cropped.
        static func squareThumbnail(from source: UIImage, side: CGFloat, scale: CGFloat) -> UIImage
        {
            let canvas = CGSize(width: side, height: side)
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
            let fitRect = aspectFitRect(sourceSize: source.size, canvasSize: canvas)
            let base = averageColor(of: source)
            return renderer.image { rendererContext in
                let context = rendererContext.cgContext
                context.interpolationQuality = .high
                let full = CGRect(origin: .zero, size: canvas)
                // 1) Opaque tonal base — guarantees no empty margins.
                base.setFill()
                context.fill(full)
                // 2) Soft blurred wash of the cover, aspect-filling the canvas.
                drawBlurredWash(source, in: canvas)
                // 3) Subtle scrim so the fitted cover separates from its wash.
                UIColor.black.withAlphaComponent(0.18).setFill()
                context.fill(full)
                // 4) The readable cover: aspect-fit, centred, never stretched/cropped.
                source.draw(in: fitRect)
            }
        }

        /// Draws a soft, deterministic blur of `source` filling `canvas`, derived
        /// by downsampling the cover to a tiny grid and upscaling it — a
        /// dependency-free "poor-man's blur" that carries the cover's colours.
        private static func drawBlurredWash(_ source: UIImage, in canvas: CGSize) {
            guard let cgImage = source.cgImage else { return }
            let tinySide = 24
            guard
                let tinyContext = CGContext(
                    data: nil, width: tinySide, height: tinySide, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            tinyContext.interpolationQuality = .high
            // Aspect-fill into the tiny square so the wash carries the cover's
            // colours edge-to-edge (no letterbox bands to upscale into bars).
            let tinyFill = aspectFillRect(
                sourceSize: source.size,
                canvasSize: CGSize(width: tinySide, height: tinySide))
            tinyContext.draw(cgImage, in: tinyFill)
            guard let tinyImage = tinyContext.makeImage() else { return }
            UIImage(cgImage: tinyImage).draw(in: CGRect(origin: .zero, size: canvas))
        }

    #endif
}
