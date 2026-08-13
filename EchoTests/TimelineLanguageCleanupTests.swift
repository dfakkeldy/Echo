// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct TimelineLanguageCleanupTests {
    private func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: "ROADMAP.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory.deletingLastPathComponent()
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot().appending(path: relativePath),
            encoding: .utf8
        )
    }

    @Test func userFacingDocsDoNotReferenceRemovedTimelineTab() throws {
        let files = [
            "EchoCore/Views/HelpContent.swift",
            "EchoCore/Views/PhonePlayerSettingsView.swift",
            "EchoCore/Localizable.xcstrings",
            "ARCHITECTURE.md",
            "docs/guides/user-manual.md",
            "docs/manual.html",
            "docs/guides/focus-field-guide.md",
            "docs/focus.html",
        ]

        for file in files {
            let text = try read(file)
            #expect(!text.contains("Timeline tab"), "\(file) still mentions the removed Timeline tab")
            #expect(!text.contains("TimelineTab"), "\(file) still mentions the removed TimelineTab type")
            #expect(!text.contains("Timeline toolbar"), "\(file) still mentions the removed Timeline toolbar")
            #expect(!text.contains("Timeline and Reader tabs"), "\(file) still describes the old Timeline/Reader tab pair")
            #expect(!text.contains("timeline, and bookmark"), "\(file) still lists the old Reader toolbar timeline button")
            #expect(!text.contains("timelineButton"), "\(file) still documents the removed timeline button")
            #expect(!text.contains("Timeline feed cells"), "\(file) still documents removed Timeline feed cells")
        }
    }
}
