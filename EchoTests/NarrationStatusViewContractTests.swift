// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationStatusViewContractTests {
    @Test func persistentCardShowsExpandableNewestFirstBoundedHistory() throws {
        let source = try Self.narrationStatusSource()

        #expect(source.contains("if state.hasSession"))
        #expect(source.contains("TimelineView(.periodic"))
        #expect(source.contains("DisclosureGroup"))
        #expect(source.contains("state.events.reversed()"))
        #expect(source.contains(".frame(maxHeight: 220)"))
    }

    @Test func cardSupportsStatusAnnouncementsDisclosureStateAndReduceMotion() throws {
        let source = try Self.narrationStatusSource()

        #expect(source.contains(".accessibilityIdentifier(\"narration.status.details\")"))
        #expect(source.contains(".accessibilityAddTraits(.updatesFrequently)"))
        #expect(source.contains("accessibilityReduceMotion"))
        #expect(source.contains("Text(\"Expanded\")"))
        #expect(source.contains("Text(\"Collapsed\")"))
    }

    @Test func viewCopyIsBilingualWithExactValues() throws {
        let strings = try Self.catalogStrings()
        let expected: [String: (en: String, nl: String)] = [
            "Details": ("Details", "Details"),
            "Expanded": ("Expanded", "Uitgevouwen"),
            "Collapsed": ("Collapsed", "Samengevouwen"),
        ]

        for (key, translations) in expected {
            let entry = try #require(
                strings[key] as? [String: Any], "Missing catalog key: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)")
            #expect(Self.translation("en", in: localizations) == translations.en)
            #expect(Self.translation("nl", in: localizations) == translations.nl)
        }
    }

    private static func narrationStatusSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
                .appendingPathComponent(
                    "EchoCore/Views/Narration/NarrationStatusView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func catalogStrings() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Localizable.xcstrings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let root = try #require(
                    try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    "Localizable.xcstrings must be a JSON object.")
                return try #require(
                    root["strings"] as? [String: Any],
                    "Localizable.xcstrings must contain strings.")
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func translation(
        _ language: String,
        in localizations: [String: Any]
    ) -> String? {
        let localization = localizations[language] as? [String: Any]
        let stringUnit = localization?["stringUnit"] as? [String: Any]
        return stringUnit?["value"] as? String
    }
}
