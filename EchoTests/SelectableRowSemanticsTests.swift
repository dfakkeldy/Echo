// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct SelectableRowSemanticsTests {
    @Test func iOSSelectableRowsUseSemanticButtons() throws {
        let soundscape = try Self.source("EchoCore/Views/SoundscapePickerView.swift")
        #expect(
            soundscape.contains("private func presetRow(_ preset: SoundscapePreset) -> some View"),
            "Soundscape preset rows should keep a focused row builder."
        )
        #expect(
            soundscape.contains("Button { selectedPreset = preset"),
            "Soundscape preset rows must use Button activation instead of tap gestures."
        )
        #expect(
            soundscape.contains(".buttonStyle(.plain)"),
            "Soundscape preset rows should preserve the existing list-row visuals."
        )
        #expect(
            !soundscape.contains(".onTapGesture"),
            "Soundscape preset rows must not be gesture-only."
        )

        let chime = try Self.source("EchoCore/Views/ChimeSettingsView.swift")
        #expect(
            chime.contains("Button { settings.chimeSound = sound.rawValue"),
            "Chime sound rows must use Button activation instead of tap gestures."
        )
        #expect(
            chime.contains(".buttonStyle(.plain)"),
            "Chime sound rows should preserve the existing list-row visuals."
        )
        #expect(
            !chime.contains(".onTapGesture"),
            "Chime sound rows must not be gesture-only."
        )
    }

    @Test func macSelectableRowsUseSemanticButtons() throws {
        let toc = try Self.source("Echo macOS/Views/MacTOCTreeView.swift")
        #expect(
            toc.contains("Button { navigateTo(node: node) } label:"),
            "macOS TOC rows must be semantic buttons so they are keyboard reachable."
        )
        #expect(
            toc.contains(".buttonStyle(.plain)"),
            "macOS TOC rows should preserve sidebar row visuals."
        )
        #expect(
            !toc.contains(".onTapGesture"),
            "macOS TOC rows must not be gesture-only."
        )

        let feed = try Self.source("Echo macOS/Views/MacReaderFeedView.swift")
        #expect(
            feed.contains("Button(action: onTap)"),
            "macOS reader cards with actions must be semantic buttons."
        )
        #expect(
            feed.contains(".buttonStyle(.plain)"),
            "macOS reader card buttons should preserve the existing card visuals."
        )
        #expect(
            !feed.contains(".onTapGesture"),
            "macOS reader cards must not be gesture-only."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.replacingOccurrences(
                    of: "\\s+", with: " ", options: .regularExpression)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
