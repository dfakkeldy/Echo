// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import CoreGraphics
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Shared test helper that synthesises a small, solid-colour cover image with
    /// known pixel dimensions. Uses ImageIO/CoreGraphics only (no UIKit/AppKit) so
    /// the fixture compiles on both iOS and macOS — the same constraint
    /// `ExportMetadata.coverArt` (raw JPEG/PNG bytes) is built around.
    enum CoverArtFixture {
        /// A `width`×`height` JPEG, encoded with ImageIO. The dimensions are baked
        /// into the pixels so a round-trip test can decode the embedded cover and
        /// assert it is the *same* image, not merely "some artwork".
        static func makeJPEG(width: Int = 240, height: Int = 240) -> Data {
            makeImageData(width: width, height: height, utType: .jpeg)
        }

        /// A `width`×`height` PNG, for exercising the non-JPEG `covr` type indicator.
        static func makePNG(width: Int = 240, height: Int = 240) -> Data {
            makeImageData(width: width, height: height, utType: .png)
        }

        private static func makeImageData(width: Int, height: Int, utType: UTType) -> Data {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.18, green: 0.52, blue: 0.86, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!

            let output = NSMutableData()
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, utType.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            _ = CGImageDestinationFinalize(destination)
            return output as Data
        }
    }
#endif
