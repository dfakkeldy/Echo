// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation;
// pure synchronous value tests over the grain generator.
nonisolated final class WashGrainTests: XCTestCase {

    /// Pixel values row by row, with any bytes-per-row alignment padding
    /// stripped — only real pixels may be asserted against the mid band.
    private func bytes(of image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        let all = [UInt8](data)
        var pixels = [UInt8]()
        pixels.reserveCapacity(image.width * image.height)
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            pixels.append(contentsOf: all[start..<(start + image.width)])
        }
        return pixels
    }

    func testTileIsDeterministicAcrossGenerations() throws {
        // The wash must render identically across launches and screenshots —
        // the grain is a fixed seeded sequence, never `random()`.
        let first = try XCTUnwrap(WashGrain.makeTile())
        let second = try XCTUnwrap(WashGrain.makeTile())
        XCTAssertEqual(bytes(of: first), bytes(of: second))
        XCTAssertFalse(bytes(of: first).isEmpty)
    }

    func testTileStaysInsideMidBand() throws {
        // Values centred on mid-grey are a no-op under `.overlay` blending;
        // anything outside the band would shift the wash's average tone.
        let tile = try XCTUnwrap(WashGrain.makeTile())
        let values = bytes(of: tile)
        XCTAssertTrue(values.allSatisfy { WashGrain.midBand.contains($0) })
        // And it is actual noise, not a flat fill.
        XCTAssertGreaterThan(Set(values).count, 16)
    }

    func testTileDimensions() throws {
        let tile = try XCTUnwrap(WashGrain.makeTile())
        XCTAssertEqual(tile.width, WashGrain.tileSize)
        XCTAssertEqual(tile.height, WashGrain.tileSize)
    }
}
