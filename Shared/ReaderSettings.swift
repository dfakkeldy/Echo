// SPDX-License-Identifier: GPL-3.0-or-later
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
    var appFont: String

    init(fontSize: Double, lineSpacing: Double, cardTintHex: String, appFont: String) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.cardTintHex = cardTintHex
        self.appFont = appFont
    }

    #if os(iOS)
    var cardTintColor: UIColor {
        UIColor(hex: cardTintHex) ?? UIColor.systemBackground
    }

    func uiFont(forTextStyle style: UIFont.TextStyle, weight: UIFont.Weight = .regular, sizeOffset: CGFloat = 0) -> UIFont {
        let baseSize: CGFloat
        switch style {
        case .largeTitle: baseSize = 34
        case .title1: baseSize = 28
        case .title2: baseSize = 22
        case .title3: baseSize = 20
        case .headline: baseSize = 17
        case .body: baseSize = 17
        case .callout: baseSize = 16
        case .subheadline: baseSize = 15
        case .footnote: baseSize = 13
        case .caption1: baseSize = 12
        case .caption2: baseSize = 11
        default: baseSize = 17
        }

        let scale = CGFloat(fontSize) / 17.0
        let targetSize = (baseSize * scale) + sizeOffset

        if appFont == "System" || appFont == "Helvetica" {
            return UIFont.systemFont(ofSize: targetSize, weight: weight)
        }

        let weightString: String
        switch weight {
        case .semibold, .bold, .heavy, .black: weightString = "SemiBold"
        default: weightString = "Regular"
        }
        
        if let font = UIFont(name: "\(appFont)-\(weightString)", size: targetSize) {
            return font
        }
        
        let desc = UIFontDescriptor(name: appFont, size: targetSize)
        var traits = desc.fontAttributes[.traits] as? [UIFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = weight
        let newDesc = desc.addingAttributes([.traits: traits])
        return UIFont(descriptor: newDesc, size: targetSize)
    }
    #endif

    /// Resolve per-book overrides against global defaults.
    static func resolved(
        fontSizeOverride: Double?,
        lineSpacingOverride: Double?,
        cardTintOverride: String?,
        appFontOverride: String?,
        globalFontSize: Double,
        globalLineSpacing: Double,
        globalCardTint: String,
        globalAppFont: String
    ) -> ReaderSettings {
        ReaderSettings(
            fontSize: fontSizeOverride ?? globalFontSize,
            lineSpacing: lineSpacingOverride ?? globalLineSpacing,
            cardTintHex: cardTintOverride ?? globalCardTint,
            appFont: appFontOverride ?? globalAppFont
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

    var contrastingTextColor: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard self.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .label }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black : .white
    }
}
#endif
