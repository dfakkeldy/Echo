// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Verifies the manual, bilingual localization catalog entries that back
/// `SlideshowVideoFormatPicker` (Task 8). Reads the raw `Localizable.xcstrings`
/// JSON directly -- the same approach as `LocalizationFormattingTests` and
/// `VideoExportUIWiringTests.newVideoExportCopyUsesManualEnglishAndDutchSymbolKeys`
/// -- so these assertions hold regardless of whether Xcode's String Catalog
/// symbol generation has run.
struct LocalizationSymbolTests {
    @Test func slideshowFormatPickerKeysAreManualBilingualWithExactCopy() throws {
        let strings = try Self.catalogStrings()
        let expected: [String: (en: String, nl: String)] = [
            "videoExportFormatLabel": ("Format", "Formaat"),
            "videoExportFormatLandscape": ("Landscape", "Liggend"),
            "videoExportFormatPortrait": ("Portrait", "Staand"),
            "videoExportFormatLandscapeAccessibilityValue": (
                "Landscape, 1920 by 1080", "Liggend, 1920 bij 1080"
            ),
            "videoExportFormatPortraitAccessibilityValue": (
                "Portrait, 1080 by 1920", "Staand, 1080 bij 1920"
            ),
            "videoExportFormatExplanation": (
                "Portrait is sized for full-screen phone viewing.",
                "Staand is bedoeld om schermvullend op de telefoon te bekijken."
            ),
            "videoExportConfigurationExportButton": ("Export video", "Video exporteren"),
        ]

        for (key, translations) in expected {
            let entry = try #require(
                strings[key] as? [String: Any], "Missing catalog key: \(key)")
            #expect(
                entry["extractionState"] as? String == "manual",
                "\(key) should be a manual catalog entry.")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Self.translation("en", in: localizations) == translations.en)
            #expect(Self.translation("nl", in: localizations) == translations.nl)
        }
    }

    @Test func formatAccessibilityValuesContainTheirExactResolutions() throws {
        let strings = try Self.catalogStrings()

        let landscape = try #require(
            strings["videoExportFormatLandscapeAccessibilityValue"] as? [String: Any])
        let landscapeLocalizations = try #require(landscape["localizations"] as? [String: Any])
        let landscapeEN = try #require(Self.translation("en", in: landscapeLocalizations))
        let landscapeNL = try #require(Self.translation("nl", in: landscapeLocalizations))
        #expect(landscapeEN.contains("1920"))
        #expect(landscapeEN.contains("1080"))
        #expect(landscapeNL.contains("1920"))
        #expect(landscapeNL.contains("1080"))

        let portrait = try #require(
            strings["videoExportFormatPortraitAccessibilityValue"] as? [String: Any])
        let portraitLocalizations = try #require(portrait["localizations"] as? [String: Any])
        let portraitEN = try #require(Self.translation("en", in: portraitLocalizations))
        let portraitNL = try #require(Self.translation("nl", in: portraitLocalizations))
        #expect(portraitEN.contains("1080"))
        #expect(portraitEN.contains("1920"))
        #expect(portraitNL.contains("1080"))
        #expect(portraitNL.contains("1920"))
    }

    @Test func task6UnsupportedVideoSettingsKeyRemainsManualAndBilingual() throws {
        let strings = try Self.catalogStrings()
        let entry = try #require(
            strings["videoExportErrorUnsupportedVideoSettings"] as? [String: Any])
        #expect(entry["extractionState"] as? String == "manual")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(Self.translation("en", in: localizations) != nil)
        #expect(Self.translation("nl", in: localizations) != nil)
    }

    private static func catalogStrings() throws -> [String: Any] {
        let catalogURL = try repositoryRoot().appending(path: "EchoCore/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Localizable.xcstrings must be a JSON object."
        )
        return try #require(
            root["strings"] as? [String: Any], "Localizable.xcstrings must contain strings.")
    }

    private static func translation(
        _ language: String,
        in localizations: [String: Any]
    ) -> String? {
        let localization = localizations[language] as? [String: Any]
        let stringUnit = localization?["stringUnit"] as? [String: Any]
        return stringUnit?["value"] as? String
    }

    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "Echo.xcodeproj").path)
            {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
