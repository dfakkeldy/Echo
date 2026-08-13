// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

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
        /// Mean OKLCH lightness of the bucket — the cover's own tone for this
        /// hue. Accent promotion seeds from it and measures identity drift
        /// against it. Defaulted mid-tone so existing constructions that never
        /// exercise promotion need no change.
        let lightness: Double
        /// The bucket's vivid core — the weighted mean of its most-chromatic
        /// quartile. Thin colourful elements (title text, fine linework)
        /// antialias into pale halo pixels that share the hue bucket and
        /// dilute the mean stats above; the core preserves the colour the eye
        /// actually reads. Nil on candidates constructed without pixel data
        /// (tests, `.neutral`), which vivid accent promotion treats as
        /// "no core view — judge by the means".
        let coreHue: Double?
        let coreChroma: Double?
        let coreLightness: Double?

        init(
            hue: Double, chroma: Double, weight: Double, lightness: Double = 0.55,
            coreHue: Double? = nil, coreChroma: Double? = nil, coreLightness: Double? = nil
        ) {
            self.hue = hue
            self.chroma = chroma
            self.weight = weight
            self.lightness = lightness
            self.coreHue = coreHue
            self.coreChroma = coreChroma
            self.coreLightness = coreLightness
        }
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

    /// The cover's border tone (OKLCH) when the outer edge ring is near-uniform —
    /// a solid field the background wash can continue seamlessly. Nil when the
    /// edge is busy. Reported even for near-neutral (white/grey/black) edges;
    /// `CoverThemeBuilder` decides whether the tone is usable. Defaulted so
    /// existing constructions need no change.
    struct EdgeField: Equatable {
        let lightness: Double
        let chroma: Double
        let hue: Double  // degrees; carries little meaning when chroma ≈ 0
    }
    var edgeField: EdgeField? = nil

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

    /// Width of the border ring inspected for a uniform edge field, in
    /// downsampled pixels (the outer 4% of the cover).
    private static let edgeRingWidth = 4

    /// A ring pixel joins the edge consensus when its OKLab distance to the
    /// ring mean is at most this — a clearly-related shade of the same field.
    private static let edgeInlierRadius = 0.10

    /// Share of ring pixels that must join the consensus. Robust to small
    /// intrusions (a figure or badge crossing the border) while rejecting
    /// genuinely split edges (two fields meeting at the border).
    private static let edgeMinInlierShare = 0.75

    /// RMS OKLab deviation the consensus itself must stay under to count as a
    /// solid field rather than a textured region that merely averages out.
    private static let edgeMaxInlierRMS = 0.045

    // MARK: - Public API

    #if canImport(UIKit)
        /// Single downsample + histogram pass emitting identity hues only.
        static func signature(from image: UIImage) -> CoverSignature {
            guard let cgImage = image.cgImage else { return .neutral }
            return signature(from: cgImage)
        }
    #endif

    /// CGImage core — platform-neutral so headless tools share the exact
    /// extraction the app uses.
    static func signature(from cgImage: CGImage) -> CoverSignature {
        guard let pixelData = downsampleAndRead(cgImage) else {
            return .neutral
        }

        var weights = [Float](repeating: 0, count: hueBuckets)
        var rSums = [Float](repeating: 0, count: hueBuckets)
        var gSums = [Float](repeating: 0, count: hueBuckets)
        var bSums = [Float](repeating: 0, count: hueBuckets)
        // Every vivid pixel, retained per bucket so each candidate can also
        // report its vivid core (most-chromatic quartile). At most 10k entries
        // for the 100×100 sample; transient for this call only.
        var bucketPixels = [[(r: Float, g: Float, b: Float, weight: Float, chroma: Double)]](
            repeating: [], count: hueBuckets)
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
            let chroma = OKLCH.fromSRGB(
                ColorMetrics.RGB(r: Double(r), g: Double(g), b: Double(b))
            ).C
            bucketPixels[bucket].append((r: r, g: g, b: b, weight: weight, chroma: chroma))
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

                // Vivid core: weighted mean of the most-chromatic quartile
                // (at least 8 pixels, or the whole bucket when smaller), so a
                // thin saturated element survives its own antialiasing halo.
                let sorted = bucketPixels[bucket].sorted { $0.chroma > $1.chroma }
                let coreCount = max(min(sorted.count, 8), (sorted.count + 3) / 4)
                let core = sorted.prefix(coreCount)
                var coreW: Float = 0
                var coreR: Float = 0
                var coreG: Float = 0
                var coreB: Float = 0
                for p in core {
                    coreW += p.weight
                    coreR += p.r * p.weight
                    coreG += p.g * p.weight
                    coreB += p.b * p.weight
                }
                let coreLCH =
                    coreW > 0
                    ? OKLCH.fromSRGB(
                        ColorMetrics.RGB(
                            r: Double(coreR / coreW),
                            g: Double(coreG / coreW),
                            b: Double(coreB / coreW)))
                    : lch

                return CoverSignature.HueCandidate(
                    hue: lch.H, chroma: lch.C, weight: Double(w), lightness: lch.L,
                    coreHue: coreLCH.H, coreChroma: coreLCH.C, coreLightness: coreLCH.L)
            }

        guard !candidates.isEmpty else { return .neutral }
        return CoverSignature(
            candidates: candidates,
            isNeutral: false,
            nearBlackShare: Double(nearBlackCount) / Double(pixelCount),
            nearWhiteShare: Double(nearWhiteCount) / Double(pixelCount),
            edgeField: detectEdgeField(pixelData))
    }

    // MARK: - Edge field

    /// Robust consensus over the border ring: mean in OKLab, keep pixels near
    /// that mean, and accept only when the inliers dominate the ring AND are
    /// themselves tight. Means live in OKLab (not LCH) because hue angles
    /// cannot be averaged across the 0°/360° seam.
    private static func detectEdgeField(_ pixelData: [UInt8]) -> CoverSignature.EdgeField? {
        struct Lab { var L: Double, a: Double, b: Double }
        var ring: [Lab] = []
        ring.reserveCapacity(4 * sampleSize * edgeRingWidth)

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let onRing =
                    x < edgeRingWidth || x >= sampleSize - edgeRingWidth
                    || y < edgeRingWidth || y >= sampleSize - edgeRingWidth
                guard onRing else { continue }
                let offset = (y * sampleSize + x) * 4
                let lch = OKLCH.fromSRGB(
                    ColorMetrics.RGB(
                        r: Double(pixelData[offset]) / 255.0,
                        g: Double(pixelData[offset + 1]) / 255.0,
                        b: Double(pixelData[offset + 2]) / 255.0))
                let radians = lch.H * .pi / 180
                ring.append(Lab(L: lch.L, a: lch.C * cos(radians), b: lch.C * sin(radians)))
            }
        }
        guard !ring.isEmpty else { return nil }

        func mean(_ points: [Lab]) -> Lab {
            let n = Double(points.count)
            return Lab(
                L: points.reduce(0) { $0 + $1.L } / n,
                a: points.reduce(0) { $0 + $1.a } / n,
                b: points.reduce(0) { $0 + $1.b } / n)
        }
        func distanceSquared(_ p: Lab, _ q: Lab) -> Double {
            let dL = p.L - q.L
            let da = p.a - q.a
            let db = p.b - q.b
            return dL * dL + da * da + db * db
        }

        let ringMean = mean(ring)
        let inliers = ring.filter {
            distanceSquared($0, ringMean) <= edgeInlierRadius * edgeInlierRadius
        }
        guard Double(inliers.count) / Double(ring.count) >= edgeMinInlierShare else { return nil }

        let field = mean(inliers)
        let rms =
            (inliers.reduce(0) { $0 + distanceSquared($1, field) } / Double(inliers.count))
            .squareRoot()
        guard rms <= edgeMaxInlierRMS else { return nil }

        let chroma = (field.a * field.a + field.b * field.b).squareRoot()
        var hue = atan2(field.b, field.a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return CoverSignature.EdgeField(lightness: field.L, chroma: chroma, hue: hue)
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
