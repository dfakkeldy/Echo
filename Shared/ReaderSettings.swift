import Foundation
import Observation

#if os(iOS)
import UIKit
#endif

/// Observable settings object for the EPUB reader feed.
/// Per-book overrides take precedence over global defaults.
@Observable
final class ReaderSettings {
    var fontSize: Double
    var lineSpacing: Double
    var cardTintHex: String

    init(fontSize: Double, lineSpacing: Double, cardTintHex: String) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.cardTintHex = cardTintHex
    }

    #if os(iOS)
    var cardTintColor: UIColor {
        UIColor(hex: cardTintHex) ?? UIColor.systemBackground
    }
    #endif

    /// Resolve per-book overrides against global defaults.
    static func resolved(
        fontSizeOverride: Double?,
        lineSpacingOverride: Double?,
        cardTintOverride: String?,
        globalFontSize: Double,
        globalLineSpacing: Double,
        globalCardTint: String
    ) -> ReaderSettings {
        ReaderSettings(
            fontSize: fontSizeOverride ?? globalFontSize,
            lineSpacing: lineSpacingOverride ?? globalLineSpacing,
            cardTintHex: cardTintOverride ?? globalCardTint
        )
    }
}

#if os(iOS)
extension UIColor {
    /// Initialize from a hex string like "#FFF8E7" or "FFF8E7".
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
            a = 1.0
        case 8:
            r = CGFloat((int >> 24) & 0xFF) / 255
            g = CGFloat((int >> 16) & 0xFF) / 255
            b = CGFloat((int >> 8) & 0xFF) / 255
            a = CGFloat(int & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
#endif
