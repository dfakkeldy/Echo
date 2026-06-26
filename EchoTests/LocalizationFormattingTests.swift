// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct LocalizationFormattingTests {
    @Test func scopedReaderFilesUseLocalizedLocaleAwareFormatting() throws {
        for relativePath in [
            "EchoCore/Views/ReaderTab+Alignment.swift",
            "EchoCore/Views/PDFDocumentView.swift",
            "EchoCore/Views/ABSConnectionsSettingsView.swift",
            "EchoCore/Models/SpeedSuggestion.swift",
            "EchoCore/Views/SessionsListView.swift",
            "EchoCore/Views/SessionDetailFeedView.swift",
            "EchoCore/Views/ReaderSettingsSheet.swift",
        ] {
            let source = try Self.source(relativePath)
            #expect(!source.contains("DateFormatter"), "\(relativePath) must use FormatStyle instead of DateFormatter.")
            #expect(!source.contains("NumberFormatter"), "\(relativePath) must use FormatStyle instead of NumberFormatter.")
            #expect(!source.contains("MeasurementFormatter"), "\(relativePath) must use FormatStyle instead of MeasurementFormatter.")
            #expect(!source.contains("String(format:"), "\(relativePath) must use FormatStyle instead of C-style formatting.")
        }

        let readerActions = try Self.source("EchoCore/Views/ReaderTab+Alignment.swift")
        #expect(!readerActions.contains("UIAccessibilityCustomAction(name: \""))
        #expect(!readerActions.contains("title: \"Auto-Align Chapters\""))
        #expect(readerActions.contains("String(localized: \"Auto-Align Chapters\")"))
        #expect(readerActions.contains("String(localized: \"No chapters or EPUB blocks found.\")"))
        #expect(readerActions.contains("String(localized: \"Bookmarked text\")"))

        let pdfActions = try Self.source("EchoCore/Views/PDFDocumentView.swift")
        #expect(pdfActions.contains("String(localized: \"PDF document\")"))
        #expect(pdfActions.contains("String(localized: \"PDF Bookmark\")"))

        let absSettings = try Self.source("EchoCore/Views/ABSConnectionsSettingsView.swift")
        #expect(absSettings.contains("String(localized: \"Invalid server URL\")"))
        #expect(absSettings.contains("String(localized: \"Could not connect: \\(error.localizedDescription)\")"))
        #expect(!absSettings.contains("errorMessage = \""))
    }

    @Test func catalogContainsManualKeysForUIKitActionsErrorsAndDynamicLabels() throws {
        let strings = try Self.catalogStrings()
        for key in [
            "%@ listened",
            "%@ travelled",
            "Align to 5s Ago",
            "Align to Chapter Start",
            "Align to Now",
            "Align to Specific Time",
            "Auto-Align Chapters",
            "Bookmarked text",
            "Change Color",
            "Copy Text",
            "Could not connect: %@",
            "Create Bookmark / Anki Card",
            "Erase Anchor",
            "Include in Audio",
            "Invalid server URL",
            "No chapters or EPUB blocks found.",
            "notInAudioThisParagraphAction",
            "notInAudioThisParagraphContextMenu",
            "notInAudioWholeChapterAction",
            "notInAudioWholeChapterContextMenu",
            "Open PDF alignment and bookmark actions",
            "PDF Actions",
            "PDF Bookmark",
            "PDF document",
            "Reset Alignment",
            "Save Bookmark",
            "Save Image",
            "Schedule %@x to finish by %@",
            "Set Chapter Theme",
            "Sepia",
            "Cream",
            "White",
            "Light Gray",
            "Soft Green",
            "Soft Blue",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "Missing catalog key: \(key)")
            #expect(entry["extractionState"] as? String == "manual", "\(key) should be a manual catalog entry.")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["en"] != nil, "\(key) should include English.")
            #expect(localizations["nl"] != nil, "\(key) should include Dutch.")
        }
    }

    @Test func formatStylesRespectNonUSLocaleSeparatorsAndUnits() {
        let dutch = Locale(identifier: "nl_NL")
        let speed = 1.5.formatted(.number.precision(.fractionLength(1)).locale(dutch))
        let distance = Measurement(value: 1.5, unit: UnitLength.miles)
            .formatted(
                .measurement(
                    width: .wide,
                    usage: .road,
                    numberFormatStyle: .number.precision(.fractionLength(1)))
                    .locale(dutch))
        let duration = Measurement(value: 2, unit: UnitDuration.minutes)
            .formatted(
                .measurement(
                    width: .wide,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0)))
                    .locale(dutch))

        #expect(speed == "1,5")
        #expect(distance.contains("2,4"))
        #expect(duration == "2 minuten")
    }

    private static func source(_ relativePath: String) throws -> String {
        let candidate = try repositoryRoot().appending(path: relativePath)
        return try String(contentsOf: candidate, encoding: .utf8)
    }

    private static func catalogStrings() throws -> [String: Any] {
        let catalogURL = try repositoryRoot().appending(path: "EchoCore/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Localizable.xcstrings must be a JSON object."
        )
        return try #require(root["strings"] as? [String: Any], "Localizable.xcstrings must contain strings.")
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
