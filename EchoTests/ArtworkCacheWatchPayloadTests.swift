// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Echo

@Suite @MainActor
struct ArtworkCacheWatchPayloadTests {
    @Test("high-entropy cover fits the WatchConnectivity payload budget")
    func highEntropyCoverFitsWatchConnectivityPayloadBudget() throws {
        let image = try #require(Self.makeHighEntropyImage(width: 800, height: 800))

        let data = try #require(ArtworkCache.makeWatchThumbnailData(from: image))

        #expect(data.count <= 60 * 1024)
    }

    private nonisolated static func makeHighEntropyImage(width: Int, height: Int) -> UIImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x4D59_5DF4_D0F3_3173

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            pixels[offset] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: state >> 32)
            pixels[offset + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent)
        else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}
