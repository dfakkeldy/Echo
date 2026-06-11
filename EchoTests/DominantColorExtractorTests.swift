import XCTest
import SwiftUI
import UIKit
@testable import Echo

final class DominantColorExtractorTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 16, height: 16)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func twoToneImage(left: UIColor, right: UIColor, leftFraction: CGFloat,
                              size: CGSize = CGSize(width: 40, height: 40)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            left.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * leftFraction, height: size.height))
            right.setFill()
            ctx.fill(CGRect(x: size.width * leftFraction, y: 0,
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
            UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()   // cream
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor(red: 0.91, green: 0.76, blue: 0.17, alpha: 1).setFill()   // gold band
            ctx.fill(CGRect(x: 0, y: 30, width: 40, height: 10))
            UIColor(red: 0.16, green: 0.28, blue: 0.39, alpha: 1).setFill()   // navy shapes
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
}
