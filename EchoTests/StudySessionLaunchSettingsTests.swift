// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct StudySessionLaunchSettingsTests {
    @Test func statsLaunchPassesGlobalNewChapterLimitFromSettings() throws {
        let source = try Self.source(named: "Stats/StatsView.swift")

        #expect(source.contains("globalNewChapterLimit:"))
        #expect(source.contains("globalNewCardLimit:"))
        #expect(source.contains("settingsManager?.studyGlobalNewChapterLimit"))
        #expect(source.contains("settingsManager?.studyNewCardsPerDayLimit"))
        #expect(source.contains("SettingsManager.Defaults.studyGlobalNewChapterLimit"))
        #expect(source.contains("SettingsManager.Defaults.studyNewCardsPerDayLimit"))
    }

    @Test func upcomingReviewsCountPassesGlobalNewChapterLimitFromSettings() throws {
        let source = try Self.source(named: "UpcomingReviewsModuleView.swift")

        #expect(source.contains("globalNewChapterLimit:"))
        #expect(source.contains("globalNewCardLimit:"))
        #expect(source.contains("settingsManager?.studyGlobalNewChapterLimit"))
        #expect(source.contains("settingsManager?.studyNewCardsPerDayLimit"))
        #expect(source.contains("SettingsManager.Defaults.studyGlobalNewChapterLimit"))
        #expect(source.contains("SettingsManager.Defaults.studyNewCardsPerDayLimit"))
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
