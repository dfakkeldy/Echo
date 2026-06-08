import UIKit
import SwiftUI

/// Extracts the most visually appropriate accent color from cover artwork.
///
/// Unlike simple "most frequent pixel" or `CIAreaAverage` (which tends toward
/// muddy grey/brown), this uses a saturation-weighted hue histogram with
/// centre-distance biasing. Pixels near grey, white, or black are ignored so
/// the result is vivid enough to serve as an interactive tint.
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

    /// The extracted colour's saturation is clamped to at least this value so
    /// the accent reads clearly against any background.
    private static let saturationFloor: Float = 0.45

    /// Lightness is nudged into this range so the tint is neither too dark nor
    /// washed out when rendered on variable backgrounds.
    private static let lightnessTargetMin: Float = 0.38
    private static let lightnessTargetMax: Float = 0.60

    // MARK: - Public API

    /// Returns the best accent colour from `image`, or `nil` if no suitable
    /// vivid region could be found (e.g. pure greyscale artwork).
    static func extract(from image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        guard let pixelData = downsampleAndRead(cgImage) else { return nil }
        return analyse(pixelData: pixelData)
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

    // MARK: - Analysis

    private struct BucketStats {
        var weight: Float = 0
        var saturationSum: Float = 0
        var lightnessSum: Float = 0
    }

    private static func analyse(pixelData: [UInt8]) -> Color? {
        var histogram = [BucketStats](repeating: BucketStats(), count: hueBuckets)
        let centre = sampleSize / 2
        let maxDistance = Float(sqrt(Double(centre * centre + centre * centre)))

        let pixelCount = sampleSize * sampleSize
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(pixelData[offset])     / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0

            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)

            // Skip neutrals — they don't make good accent colours.
            guard l > minLightness && l < maxLightness else { continue }
            guard s > minSaturation else { continue }

            // Weight by saturation squared (heavily favour vivid colours) and
            // centre-distance (subjects tend to be centred).
            let saturationWeight = s * s
            let x = Float(i % sampleSize)
            let y = Float(i / sampleSize)
            let dx = x - Float(centre)
            let dy = y - Float(centre)
            let distance = sqrt(dx * dx + dy * dy)
            let centreWeight = 1.0 - (distance / maxDistance) * 0.4

            let weight = saturationWeight * centreWeight

            let bucket = min(Int(h * Float(hueBuckets)), hueBuckets - 1)
            histogram[bucket].weight += weight
            histogram[bucket].saturationSum += s * weight
            histogram[bucket].lightnessSum += l * weight
        }

        // Find the bucket with the most weighted votes.
        guard let best = histogram.max(by: { $0.weight < $1.weight }),
              best.weight > 0 else { return nil }

        let avgSaturation = best.saturationSum / best.weight
        let avgLightness = best.lightnessSum / best.weight

        // Boost saturation so the accent pops.
        let finalS = max(avgSaturation, saturationFloor)
        // Nudge lightness into a readable UI range.
        let finalL = min(max(avgLightness, lightnessTargetMin), lightnessTargetMax)

        // Reconstruct the hue from the bucket index.
        let finalH = Float(histogram.firstIndex(where: { $0.weight == best.weight }) ?? 0) / Float(hueBuckets)

        let (cr, cg, cb) = hslToRGB(h: finalH, s: finalS, l: finalL)
        return Color(red: Double(cr), green: Double(cg), blue: Double(cb))
    }

    /// Returns the top `count` dominant colors from `image`, or default colors if none can be extracted.
    static func extractColors(from image: UIImage, count: Int = 3) -> [Color] {
        guard let cgImage = image.cgImage else {
            return [Color.blue, Color.purple, Color.indigo]
        }
        guard let pixelData = downsampleAndRead(cgImage) else {
            return [Color.blue, Color.purple, Color.indigo]
        }
        return analyseMultiple(pixelData: pixelData, count: count)
    }

    private static func analyseMultiple(pixelData: [UInt8], count: Int) -> [Color] {
        var histogram = [BucketStats](repeating: BucketStats(), count: hueBuckets)
        let centre = sampleSize / 2
        let maxDistance = Float(sqrt(Double(centre * centre + centre * centre)))

        let pixelCount = sampleSize * sampleSize
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(pixelData[offset])     / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0

            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)

            // Skip neutrals
            guard l > minLightness && l < maxLightness else { continue }
            guard s > minSaturation else { continue }

            let saturationWeight = s * s
            let x = Float(i % sampleSize)
            let y = Float(i / sampleSize)
            let dx = x - Float(centre)
            let dy = y - Float(centre)
            let distance = sqrt(dx * dx + dy * dy)
            let centreWeight = 1.0 - (distance / maxDistance) * 0.4

            let weight = saturationWeight * centreWeight

            let bucket = min(Int(h * Float(hueBuckets)), hueBuckets - 1)
            histogram[bucket].weight += weight
            histogram[bucket].saturationSum += s * weight
            histogram[bucket].lightnessSum += l * weight
        }

        // Get non-zero buckets sorted by weight descending
        let sortedBuckets = histogram.enumerated()
            .filter { $0.element.weight > 0 }
            .sorted(by: { $0.element.weight > $1.element.weight })

        if sortedBuckets.isEmpty {
            return [Color.blue, Color.purple, Color.indigo]
        }

        var results: [Color] = []
        for i in 0..<min(count, sortedBuckets.count) {
            let index = sortedBuckets[i].offset
            let stats = sortedBuckets[i].element

            let avgSaturation = stats.saturationSum / stats.weight
            let avgLightness = stats.lightnessSum / stats.weight

            let finalS = max(avgSaturation, saturationFloor)
            let finalL = min(max(avgLightness, lightnessTargetMin), lightnessTargetMax)
            let finalH = Float(index) / Float(hueBuckets)

            let (cr, cg, cb) = hslToRGB(h: finalH, s: finalS, l: finalL)
            results.append(Color(red: Double(cr), green: Double(cg), blue: Double(cb)))
        }

        // Pad with slightly shifted/opacity variations if fewer than count
        while results.count < count {
            if let first = results.first {
                results.append(first.opacity(0.6))
            } else {
                results.append(Color.accentColor)
            }
        }

        return results
    }


    // MARK: - Colour Space Conversions

    /// Converts RGB (0…1) to HSL (0…1).
    private static func rgbToHSL(r: Float, g: Float, b: Float) -> (h: Float, s: Float, l: Float) {
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

    /// Converts HSL (0…1) to RGB (0…1).
    private static func hslToRGB(h: Float, s: Float, l: Float) -> (r: Float, g: Float, b: Float) {
        guard s > 0.0001 else {
            return (l, l, l)
        }

        func hueToRGB(_ p: Float, _ q: Float, _ t: Float) -> Float {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }

        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2.0 * l - q

        let r = hueToRGB(p, q, h + 1.0 / 3.0)
        let g = hueToRGB(p, q, h)
        let b = hueToRGB(p, q, h - 1.0 / 3.0)

        return (r, g, b)
    }
}
