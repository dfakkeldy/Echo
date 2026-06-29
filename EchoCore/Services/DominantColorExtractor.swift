// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// What a cover IS — its identity hues — with no opinion about how the UI
/// should look. `CoverThemeBuilder` owns appearance.
// `nonisolated`: a pure value signature (with the nested `HueCandidate`). Under
// Swift 6 MainActor default isolation it would be inferred `@MainActor`, blocking
// the nonisolated extractor/tests from reading it.
nonisolated struct CoverSignature: Equatable {
    struct HueCandidate: Equatable {
        let hue: Double  // OKLCH hue angle, degrees
        let chroma: Double  // mean OKLCH chroma of the bucket
        let weight: Double  // saturation² × centre-bias coverage score
    }
    /// Ranked by weight, descending. Empty for neutral covers.
    let candidates: [HueCandidate]
    /// True when the cover carries no usable identity hue: either too few vivid
    /// pixels in absolute terms (a stray speck), or vivid pixels don't dominate
    /// the *colourable* (non-black/white) region. High-contrast covers — a bold
    /// accent on black/white — are NOT neutral even though the accent is a small
    /// fraction of the whole canvas.
    let isNeutral: Bool

    /// Share (0…1) of all sampled pixels that are near-black / near-white. When
    /// both are large the cover is "high-contrast" (a bold accent on black/white),
    /// which `CoverThemeBuilder` themes with a neutral graphite/paper background
    /// ramp instead of a tonal hue ramp. Defaulted so existing constructions
    /// (tests, `.neutral`) need no change.
    var nearBlackShare: Double = 0
    var nearWhiteShare: Double = 0

    static let neutral = CoverSignature(candidates: [], isNeutral: true)
}

/// Extracts identity hues from cover artwork for the tonal-theme pipeline.
///
/// Uses a saturation²-weighted hue histogram with centre-distance biasing.
/// Pixels near grey, white, or black are ignored. The extractor reports what
/// the cover IS; `CoverThemeBuilder` decides how the UI looks.
// `nonisolated`: pure image-pixel color analysis; the `UIImage`/`CGImage` inputs are
// used synchronously and never escape, so no main-actor isolation is required.
nonisolated enum DominantColorExtractor {

    // MARK: - Configuration

    /// How many hue buckets to quantize into (higher = finer distinctions).
    private static let hueBuckets = 24

    /// Downsample target — small enough for speed, large enough for accuracy.
    private static let sampleSize = 100

    /// Pixels darker than this are treated as near-black and skipped.
    private static let minLightness: Float = 0.12

    /// Pixels lighter than this are treated as near-white and skipped.
    private static let maxLightness: Float = 0.93

    /// Pixels with saturation below this are treated as near-grey and skipped.
    private static let minSaturation: Float = 0.12

    /// Minimum share of the *colourable* (non-black/white) pixels that must be
    /// vivid for the cover to count as colourful. Measuring against the colourable
    /// region — not the whole canvas — is what lets a bold accent on a
    /// high-contrast black/white cover register: the black/white bulk is excluded,
    /// so the accent dominates what remains.
    private static let minVividCoverage: Double = 0.02

    /// Absolute floor (as a fraction of all sampled pixels) on the vivid-pixel
    /// count. Guards against a stray speck theming a book on covers where the
    /// colourable region is itself tiny (e.g. a single colour pixel on pure
    /// white, where the colourable share would otherwise be 100%).
    private static let minVividPixelFraction: Double = 0.004

    // MARK: - Public API

    /// Single downsample + histogram pass emitting identity hues only.
    static func signature(from image: UIImage) -> CoverSignature {
        guard let cgImage = image.cgImage,
            let pixelData = downsampleAndRead(cgImage)
        else {
            return .neutral
        }

        var weights = [Float](repeating: 0, count: hueBuckets)
        var rSums = [Float](repeating: 0, count: hueBuckets)
        var gSums = [Float](repeating: 0, count: hueBuckets)
        var bSums = [Float](repeating: 0, count: hueBuckets)
        var vividCount = 0
        var colorableCount = 0
        var nearBlackCount = 0
        var nearWhiteCount = 0

        let centre = sampleSize / 2
        let maxDistance = Float(sqrt(Double(centre * centre + centre * centre)))
        let pixelCount = sampleSize * sampleSize

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(pixelData[offset]) / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0

            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            if l <= minLightness { nearBlackCount += 1 }
            if l >= maxLightness { nearWhiteCount += 1 }
            guard l > minLightness && l < maxLightness else { continue }
            // This pixel could carry a hue (it isn't near-black or near-white).
            colorableCount += 1
            guard s > minSaturation else { continue }
            vividCount += 1

            let saturationWeight = s * s
            let x = Float(i % sampleSize)
            let y = Float(i / sampleSize)
            let dx = x - Float(centre)
            let dy = y - Float(centre)
            let distance = sqrt(dx * dx + dy * dy)
            let centreWeight = 1.0 - (distance / maxDistance) * 0.4
            let weight = saturationWeight * centreWeight

            let bucket = min(Int(h * Float(hueBuckets)), hueBuckets - 1)
            weights[bucket] += weight
            rSums[bucket] += r * weight
            gSums[bucket] += g * weight
            bSums[bucket] += b * weight
        }

        // Two gates: enough vivid pixels in absolute terms (stray-speck guard),
        // AND vivid pixels dominate the colourable (non-black/white) region. The
        // second gate is what admits a bold accent on a high-contrast cover.
        guard Double(vividCount) >= minVividPixelFraction * Double(pixelCount) else {
            return .neutral
        }
        let coverage = Double(vividCount) / Double(max(1, colorableCount))
        guard coverage >= minVividCoverage else { return .neutral }

        let candidates = (0..<hueBuckets)
            .filter { weights[$0] > 0 }
            .sorted { weights[$0] > weights[$1] }
            .map { bucket -> CoverSignature.HueCandidate in
                let w = weights[bucket]
                let mean = ColorMetrics.RGB(
                    r: Double(rSums[bucket] / w),
                    g: Double(gSums[bucket] / w),
                    b: Double(bSums[bucket] / w)
                )
                let lch = OKLCH.fromSRGB(mean)
                return CoverSignature.HueCandidate(hue: lch.H, chroma: lch.C, weight: Double(w))
            }

        guard !candidates.isEmpty else { return .neutral }
        return CoverSignature(
            candidates: candidates,
            isNeutral: false,
            nearBlackShare: Double(nearBlackCount) / Double(pixelCount),
            nearWhiteShare: Double(nearWhiteCount) / Double(pixelCount))
    }

    // MARK: - Downsampling

    private static func downsampleAndRead(_ cgImage: CGImage) -> [UInt8]? {
        let size = CGSize(width: sampleSize, height: sampleSize)
        guard
            let ctx = CGContext(
                data: nil,
                width: sampleSize,
                height: sampleSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let resized = ctx.makeImage(),
            let dataProvider = resized.dataProvider,
            let data = dataProvider.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let byteCount = CFDataGetLength(data)
        return Array(UnsafeBufferPointer(start: bytes, count: byteCount))
    }

    // MARK: - Colour Space Conversions

    /// Converts RGB (0…1) to HSL (0…1).
    static func rgbToHSL(r: Float, g: Float, b: Float) -> (h: Float, s: Float, l: Float) {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let l = (maxVal + minVal) / 2.0

        let delta = maxVal - minVal
        guard delta > 0.0001 else {
            return (0, 0, l)  // achromatic
        }

        let s: Float =
            l > 0.5
            ? delta / (2.0 - maxVal - minVal)
            : delta / (maxVal + minVal)

        var h: Float
        switch maxVal {
        case r:
            h = (g - b) / delta + (g < b ? 6.0 : 0.0)
        case g:
            h = (b - r) / delta + 2.0
        case b:
            h = (r - g) / delta + 4.0
        default:
            h = 0
        }
        h /= 6.0

        return (h, s, l)
    }
}
