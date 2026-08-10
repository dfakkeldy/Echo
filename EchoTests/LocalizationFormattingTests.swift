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

    @Test func narrationStatusFormatterKeysAreManualBilingualWithMatchingInterpolations() throws {
        let strings = try Self.catalogStrings()
        let expected: [String: (en: String, nl: String)] = [
            "%@ chapter %lld": ("%1$@ chapter %2$lld", "%1$@ hoofdstuk %2$lld"),
            "%@. %@": ("%1$@. %2$@", "%1$@. %2$@"),
            "%@s elapsed": ("%@s elapsed", "%@ s verstreken"),
            "%@ · %@ · %@ · %lld%%": (
                "%1$@ · %2$@ · %3$@ · %4$lld%%",
                "%1$@ · %2$@ · %3$@ · %4$lld%%"
            ),
            "%@ · %lld ready ahead": (
                "%1$@ · %2$lld ready ahead",
                "%1$@ · %2$lld vooruit gereed"
            ),
            "%@ · %lld%%": ("%1$@ · %2$lld%%", "%1$@ · %2$lld%%"),
            "%lld MB": ("%lld MB", "%lld MB"),
            "%lld MB expected": ("%lld MB expected", "%lld MB verwacht"),
            "%lld of %lld MB": ("%1$lld of %2$lld MB", "%1$lld van %2$lld MB"),
            "All chapters rendered": ("All chapters rendered", "Alle hoofdstukken zijn gerenderd"),
            "Checking narration model": ("Checking narration model", "Vertelmodel controleren"),
            "Downloading narration model": ("Downloading narration model", "Vertelmodel downloaden"),
            "Loading": ("Loading", "Laden"),
            "Loading narration audio": ("Loading narration audio", "Vertellingsaudio laden"),
            "Loading narration model": ("Loading narration model", "Vertelmodel laden"),
            "Narration cancelled": ("Narration cancelled", "Vertelling geannuleerd"),
            "Narration model ready": ("Narration model ready", "Vertelmodel gereed"),
            "Narration ready": ("Narration ready", "Vertelling gereed"),
            "Narration stopped": ("Narration stopped", "Vertelling gestopt"),
            "Narration unavailable": ("Narration unavailable", "Vertelling niet beschikbaar"),
            "No narratable text was found": (
                "No narratable text was found",
                "Geen vertelbare tekst gevonden"
            ),
            "Paused": ("Paused", "Gepauzeerd"),
            "Planning narration": ("Planning narration", "Vertelling plannen"),
            "Playback completed": ("Playback completed", "Afspelen voltooid"),
            "Playing": ("Playing", "Wordt afgespeeld"),
            "Ready to play": ("Ready to play", "Gereed om af te spelen"),
            "Rendering": ("Rendering", "Renderen"),
            "Rendering chapter %lld": ("Rendering chapter %lld", "Hoofdstuk %lld renderen"),
            "Rendering chapter %lld with %@": (
                "Rendering chapter %1$lld with %2$@",
                "Hoofdstuk %1$lld renderen met %2$@"
            ),
            "Rendering chapter %lld, segment %lld": (
                "Rendering chapter %1$lld, segment %2$lld",
                "Hoofdstuk %1$lld, segment %2$lld renderen"
            ),
            "Rendering paused while playback catches up": (
                "Rendering paused while playback catches up",
                "Renderen gepauzeerd terwijl het afspelen inloopt"
            ),
            "Rendering segment %lld": ("Rendering segment %lld", "Segment %lld renderen"),
            "Resuming": ("Resuming", "Hervatten"),
            "Still synthesizing block %lld · no update for %llds": (
                "Still synthesizing block %1$lld · no update for %2$llds",
                "Blok %1$lld wordt nog gesynthetiseerd · %2$lld s geen update"
            ),
            "Unable to load narration audio": (
                "Unable to load narration audio",
                "Vertellingsaudio kan niet worden geladen"
            ),
            "Validating narration model": ("Validating narration model", "Vertelmodel valideren"),
            "Waiting for": ("Waiting for", "Wachten op"),
            "block %lld of %lld": ("block %1$lld of %2$lld", "blok %1$lld van %2$lld"),
        ]

        for (key, translations) in expected {
            let entry = try #require(
                strings[key] as? [String: Any], "Missing narration status catalog key: \(key)")
            #expect(entry["extractionState"] as? String == "manual")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try Self.translation(in: localizations, language: "en")
            let dutch = try Self.translation(in: localizations, language: "nl")
            #expect(english == translations.en, "Unexpected English translation for \(key).")
            #expect(dutch == translations.nl, "Unexpected Dutch translation for \(key).")
            #expect(Self.interpolationTypes(in: english) == Self.interpolationTypes(in: key))
            #expect(Self.interpolationTypes(in: dutch) == Self.interpolationTypes(in: key))
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

    private static func translation(
        in localizations: [String: Any],
        language: String
    ) throws -> String {
        let localization = try #require(localizations[language] as? [String: Any])
        let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
        return try #require(stringUnit["value"] as? String)
    }

    private static func interpolationTypes(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(lld|@)"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[capture])
        }.sorted()
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
