import SwiftUI
import UIKit
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class DominantColorExtractorTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 16, height: 16))
        -> UIImage
    {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func twoToneImage(
        left: UIColor, right: UIColor, leftFraction: CGFloat,
        size: CGSize = CGSize(width: 40, height: 40)
    ) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            left.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * leftFraction, height: size.height))
            right.setFill()
            ctx.fill(
                CGRect(
                    x: size.width * leftFraction, y: 0,
                    width: size.width * (1 - leftFraction), height: size.height))
        }
    }

    func testSignatureOfVividCoverIsNotNeutral() {
        let sig = DominantColorExtractor.signature(from: solidImage(.systemRed))
        XCTAssertFalse(sig.isNeutral)
        XCTAssertFalse(sig.candidates.isEmpty)
        // sRGB reds sit near hue 29° in OKLCH
        XCTAssertEqual(sig.candidates[0].hue, 29.0, accuracy: 15.0)
        XCTAssertGreaterThan(sig.candidates[0].chroma, 0.05)
    }

    func testSignatureOfGreyscaleCoverIsNeutral() {
        let sig = DominantColorExtractor.signature(from: solidImage(.gray))
        XCTAssertTrue(sig.isNeutral)
        XCTAssertTrue(sig.candidates.isEmpty)
    }

    func testSparseVividPixelsFallBelowCoverageFloor() {
        // One vivid 1×1 patch on a 40×40 grey field — far below the 2% floor.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(DominantColorExtractor.signature(from: image).isNeutral)
    }

    func testTwoToneCoverRanksLargerRegionFirst() {
        // 75% blue / 25% red → the blue family must rank first.
        let sig = DominantColorExtractor.signature(
            from: twoToneImage(left: .systemBlue, right: .systemRed, leftFraction: 0.75)
        )
        XCTAssertGreaterThanOrEqual(sig.candidates.count, 2)
        XCTAssertEqual(sig.candidates[0].hue, 258.0, accuracy: 25.0)
    }

    func testSyntheticCompanyOfOneCover() {
        // Spec §7: cream field (filtered as near-white), gold band, navy shapes.
        // Expect: not neutral, a warm primary (sat² favours the vivid gold), and
        // a navy-family candidate available for the secondary role.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()  // cream
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor(red: 0.91, green: 0.76, blue: 0.17, alpha: 1).setFill()  // gold band
            ctx.fill(CGRect(x: 0, y: 30, width: 40, height: 10))
            UIColor(red: 0.16, green: 0.28, blue: 0.39, alpha: 1).setFill()  // navy shapes
            ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 30))
        }
        let sig = DominantColorExtractor.signature(from: image)
        XCTAssertFalse(sig.isNeutral)
        XCTAssertEqual(sig.candidates[0].hue, 95.0, accuracy: 25.0)  // warm gold leads
        XCTAssertTrue(
            sig.candidates.contains { $0.hue > 230 && $0.hue < 290 },
            "expected a navy-family candidate for the secondary role"
        )
    }

    func testHighContrastCoverWithBoldAccentIsNotNeutral() {
        // Models a high-contrast cover (à la "Everything But the Code"): a
        // black/white field with a small but bold red accent. The red is < 2% of
        // the whole canvas — so it would historically fall below the coverage
        // floor — but it dominates the colourable (non-black/white) region, so the
        // theme must derive from it rather than collapsing to neutral.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))  // left half black
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 70, y: 44, width: 12, height: 12))  // 144 px ≈ 1.44% of canvas
        }
        let sig = DominantColorExtractor.signature(from: image)
        XCTAssertFalse(sig.isNeutral, "a bold accent on a black/white cover must not be neutral")
        XCTAssertFalse(sig.candidates.isEmpty)
        XCTAssertEqual(sig.candidates[0].hue, 29.0, accuracy: 20.0)  // red leads (OKLCH ~29°)
    }

    func testSingleSaturatedSpeckOnWhiteStaysNeutral() {
        // Guards the absolute vivid-pixel floor: a speck on pure white would have
        // ~100% colourable-share, so the relative gate alone would admit it — the
        // absolute floor must still reject it as a stray pixel.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: 4, height: 4))  // 16 px ≈ 0.16% < 0.4% floor
        }
        XCTAssertTrue(DominantColorExtractor.signature(from: image).isNeutral)
    }

    func testHighContrastCoverReportsBlackAndWhiteShares() {
        // The black/white + red fixture should report large near-black AND
        // near-white shares — the signal CoverThemeBuilder uses to switch to the
        // neutral graphite/paper background ramp.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))  // left half black
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 70, y: 44, width: 12, height: 12))
        }
        let sig = DominantColorExtractor.signature(from: image)
        XCTAssertGreaterThan(sig.nearBlackShare, 0.3, "left-half black → large near-black share")
        XCTAssertGreaterThan(sig.nearWhiteShare, 0.3, "right-half white → large near-white share")
        XCTAssertGreaterThan(
            sig.nearBlackShare + sig.nearWhiteShare, 0.45, "cover reads as black/white-dominant")
    }

    func testColourfulCoverHasLowBlackWhiteShares() {
        // A solid vivid cover has almost no near-black/near-white pixels, so it must
        // NOT trip the neutral-ramp share gate.
        let sig = DominantColorExtractor.signature(
            from: solidImage(.systemRed, size: CGSize(width: 100, height: 100)))
        XCTAssertLessThan(sig.nearBlackShare + sig.nearWhiteShare, 0.1)
    }
}
