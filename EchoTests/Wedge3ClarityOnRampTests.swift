// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct Wedge3ClarityOnRampTests {
    @Test func rootPresentsFirstLaunchOnboardingUntilSeen() throws {
        let source = try Self.viewSource(named: "RootTabView.swift")

        #expect(source.contains("@AppStorage(\"hasSeenOnboarding\")"))
        #expect(source.contains("firstLaunchOnboardingBinding"))
        #expect(source.contains("OnboardingView()"))
    }

    @Test func onboardingTeachesCoreWorkflowInFourSteps() throws {
        let source = try Self.viewSource(named: "OnboardingView.swift")

        #expect(source.contains("Import"))
        #expect(source.contains("Align"))
        #expect(source.contains("Capture"))
        #expect(source.contains("Review"))
        #expect(source.contains("TabView"))
        #expect(source.contains("Get Started"))
    }

    @Test func readerEmptyStateIsAnActionableOnRamp() throws {
        let source = try Self.viewSource(named: "ReaderEmptyState.swift")
        let root = try Self.viewSource(named: "RootTabView.swift")
        let folderPicker = try Self.utilitySource(named: "FolderPicker.swift")

        #expect(
            source.contains("Add an EPUB for searchable text, or a PDF for page-based reading and alignment.")
        )
        #expect(source.contains("Choose an audiobook, EPUB, or transcript to start reading and studying."))
        #expect(source.contains("Button(\"Add Document\", systemImage: \"plus\")"))
        #expect(source.contains("Button(\"Choose Book\", systemImage: \"folder\")"))
        #expect(root.contains("hasLoadedBook: model.folderURL != nil"))
        #expect(root.contains("model.showingDocumentImporter = true"))
        #expect(root.contains("showingFolderPicker = true"))
        #expect(!folderPicker.contains(".pdf"))
    }

    @Test func studyReviewLaunchFailureIsVisible() throws {
        let stats = try Self.viewSource(named: "Stats/StatsView.swift")

        #expect(stats.contains("@State private var studySessionLaunchError"))
        #expect(stats.contains("\"Could Not Start Study\""))
        #expect(stats.contains("studySessionLaunchError = String("))
        #expect(stats.contains("Failed to launch study session"))
        #expect(stats.contains("Button(\"Review Queue\", systemImage: \"rectangle.stack.fill\""))
    }

    private static func viewSource(named fileName: String) throws -> String {
        try Self.source(directoryName: "EchoCore/Views", fileName: fileName)
    }

    private static func utilitySource(named fileName: String) throws -> String {
        try Self.source(directoryName: "EchoCore/Utilities", fileName: fileName)
    }

    private static func source(directoryName: String, fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appending(path: directoryName)
                .appending(path: fileName)

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
