// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchWidgetPresentationSourceTests {
    @Test("widget timeline entries carry the persisted cover accent")
    func widgetEntryCarriesAccent() {
        let source = Self.sourceIfPresent(at: "Echo Widget/Views/Echo_Widget.swift")

        #expect(source.contains("let artworkAccentColorHex: String?"))
        #expect(source.contains("defaults.string(forKey: \"artworkAccentColorHex\")"))
        #expect(source.contains("artworkAccentColorHex: artworkAccentColorHex"))
    }

    static func sourceIfPresent(at relativePath: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return
            (try? String(
                contentsOf: repositoryRoot.appending(path: relativePath),
                encoding: .utf8
            )) ?? ""
    }
}
