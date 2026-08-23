// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct StudySessionLaunchSettingsTests {
    @Test func statsLaunchUsesViewModelAsSheetItem() throws {
        let source = try Self.source(named: "Stats/StatsView.swift")

        #expect(source.contains(".sheet(item: $studySessionViewModel)"))
        #expect(!source.contains("@State private var showingStudySession"))
        #expect(!source.contains(".sheet(isPresented: $showingStudySession)"))
    }

    /// `.sheet(item:)` compiles against the free `Identifiable` conformance
    /// `AnyObject` provides, whose `id` is the object address and can be reused
    /// once a dismissed session deallocates. A stable stored id keeps a new
    /// session from being mistaken for the one just dismissed.
    @Test func studySessionViewModelCarriesAStableIdentity() throws {
        let source = try Self.source(
            named: "StudySessionViewModel.swift", under: "EchoCore/ViewModels")

        #expect(source.contains("final class StudySessionViewModel: Identifiable"))
        #expect(source.contains("let id = UUID()"))
    }

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

    private static func source(
        named fileName: String, under directoryPath: String = "EchoCore/Views"
    ) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent(directoryPath)
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
