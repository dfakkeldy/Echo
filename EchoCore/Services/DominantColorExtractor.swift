import UIKit

/// What a cover IS — its identity hues — with no opinion about how the UI
/// should look. `CoverThemeBuilder` owns appearance.
struct CoverSignature: Equatable {
    struct HueCandidate: Equatable {
        let hue: Double      // OKLCH hue angle, degrees
        let chroma: Double   // mean OKLCH chroma of the bucket
        let weight: Double   // saturation² × centre-bias coverage score
    }
    /// Ranked by weight, descending. Empty for neutral covers.
    let candidates: [HueCandidate]
    /// True when vivid pixels cover < 2% of the sample (or none at all).
    let isNeutral: Bool

    static let neutral = CoverSignature(candidates: [], isNeutral: true)
}

/// Extracts identity hues from cover artwork for the tonal-theme pipeline.
///
/// Uses a saturation²-weighted hue histogram with centre-distance biasing.
/// Pixels near grey, white, or black are ignored. The extractor reports what
/// the cover IS; `CoverThemeBuilder` decides how the UI looks.
enum DominantColorExtractor {

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

    /// Minimum fraction of sampled pixels that must be vivid for the cover to
    /// count as colourful — below this, a stray pixel could theme a book.
    private static let minVividCoverage: Double = 0.02

    // MARK: - Public API

    /// Single downsample + histogram pass emitting identity hues only.
    static func signature(from image: UIImage) -> CoverSignature {
        guard let cgImage = image.cgImage,
              let pixelData = downsampleAndRead(cgImage) else {
            return .neutral
        }

        var weights = [Float](repeating: 0, count: hueBuckets)
        var rSums = [Float](repeating: 0, count: hueBuckets)
        var gSums = [Float](repeating: 0, count: hueBuckets)
        var bSums = [Float](repeating: 0, count: hueBuckets)
        var vividCount = 0

        let centre = sampleSize / 2
        let maxDistance = Float(sqrt(Double(centre * centre + centre * centre)))
        let pixelCount = sampleSize * sampleSize

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(pixelData[offset])     / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0

            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            guard l > minLightness && l < maxLightness else { continue }
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

        let coverage = Double(vividCount) / Double(pixelCount)
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
        return CoverSignature(candidates: candidates, isNeutral: false)
    }

    // MARK: - Downsampling

    private static func downsampleAndRead(_ cgImage: CGImage) -> [UInt8]? {
        let size = CGSize(width: sampleSize, height: sampleSize)
        guard let ctx = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let resized = ctx.makeImage(),
              let dataProvider = resized.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

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
            return (0, 0, l) // achromatic
        }

        let s: Float = l > 0.5
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
