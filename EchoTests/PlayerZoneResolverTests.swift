// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Testing

@testable import Echo

struct PlayerZoneResolverTests {
    private let size = CGSize(width: 390, height: 844)
    private let diameter: CGFloat = 56

    @Test func everyZoneStaysFullyOnScreenEvenWithMaxNudge() {
        for zone in PlayerSnapZone.allCases {
            for offset in [
                CGSize(width: 999, height: 999), CGSize(width: -999, height: -999), CGSize.zero,
            ] {
                let c = PlayerZoneResolver.center(
                    for: zone, offset: offset, in: size, diameter: diameter)
                #expect(c.x >= diameter / 2 && c.x <= size.width - diameter / 2)
                #expect(c.y >= diameter / 2 && c.y <= size.height - diameter / 2)
            }
        }
    }

    @Test func offsetIsClampedToMaxNudge() {
        let base = PlayerZoneResolver.center(
            for: .midLeading, offset: .zero, in: size, diameter: diameter)
        let nudged = PlayerZoneResolver.center(
            for: .midLeading, offset: CGSize(width: 999, height: 0), in: size, diameter: diameter)
        #expect(abs(nudged.x - base.x) <= PlayerZoneResolver.maxNudge + 0.001)
    }

    @Test func lowerCenterIsHorizontallyCentered() {
        let c = PlayerZoneResolver.center(
            for: .lowerCenter, offset: .zero, in: size, diameter: diameter)
        #expect(abs(c.x - size.width / 2) < 0.001)
    }
}
