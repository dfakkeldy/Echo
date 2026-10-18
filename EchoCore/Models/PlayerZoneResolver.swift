// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Pure geometry for the experimental player's snap zones. Kept UIKit-free and
/// stateless so it unit-tests without any view in the loop.
enum PlayerZoneResolver {
    /// Maximum fine-tune distance (points) from a zone's anchor, per axis.
    static let maxNudge: CGFloat = 28
    /// Inset of edge anchors from the container bounds.
    static let edgeMargin: CGFloat = 24
    /// Vertical anchor fractions of container height.
    private static let upperY: CGFloat = 0.18
    private static let midY: CGFloat = 0.68
    private static let lowerY: CGFloat = 0.88

    static func anchor(for zone: PlayerSnapZone, in size: CGSize, diameter: CGFloat) -> CGPoint {
        let leadingX = edgeMargin + diameter / 2
        let trailingX = size.width - edgeMargin - diameter / 2
        let centerX = size.width / 2
        switch zone {
        case .upperLeading: return CGPoint(x: leadingX, y: size.height * upperY)
        case .upperTrailing: return CGPoint(x: trailingX, y: size.height * upperY)
        case .midLeading: return CGPoint(x: leadingX, y: size.height * midY)
        case .midTrailing: return CGPoint(x: trailingX, y: size.height * midY)
        case .lowerLeading: return CGPoint(x: leadingX, y: size.height * lowerY)
        case .lowerCenter: return CGPoint(x: centerX, y: size.height * lowerY)
        case .lowerTrailing: return CGPoint(x: trailingX, y: size.height * lowerY)
        }
    }

    static func center(
        for zone: PlayerSnapZone, offset: CGSize, in size: CGSize, diameter: CGFloat
    ) -> CGPoint {
        let anchor = anchor(for: zone, in: size, diameter: diameter)
        let clampedOffset = CGSize(
            width: min(max(offset.width, -maxNudge), maxNudge),
            height: min(max(offset.height, -maxNudge), maxNudge))
        let radius = diameter / 2
        return CGPoint(
            x: min(max(anchor.x + clampedOffset.width, radius), size.width - radius),
            y: min(max(anchor.y + clampedOffset.height, radius), size.height - radius))
    }

    /// The zone whose anchor is closest to `point` (drag-drop target, Task 3).
    static func nearestZone(to point: CGPoint, in size: CGSize, diameter: CGFloat) -> PlayerSnapZone
    {
        PlayerSnapZone.allCases.min { a, b in
            distanceSquared(point, anchor(for: a, in: size, diameter: diameter))
                < distanceSquared(point, anchor(for: b, in: size, diameter: diameter))
        } ?? .lowerCenter
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}
