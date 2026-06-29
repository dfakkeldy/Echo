// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct Wedge3ClarityOnRampTests {
    @Test func libraryShowsActionFirstLanding() throws {
        let tab = try Self.viewSource(named: "NowPlayingTab.swift")
        let library = try Self.viewSource(named: "Library/LibraryView.swift")

        #expect(tab.contains("model.selectedTab = .library"))
        #expect(library.contains("onConnectServer"))
        #expect(library.contains("Button(\"Open a Folder\", systemImage: \"folder\""))
        #expect(!tab.contains("NowPlayingEmptyState("))
    }

    @Test func rootNoLongerPresentsOnboardingSlideshow() throws {
        let root = try Self.viewSource(named: "RootTabView.swift")

        #expect(!root.contains("OnboardingView()"))
        #expect(!root.contains("firstLaunchOnboardingBinding"))
        #expect(!root.contains("hasSeenOnboarding"))
    }

    @Test func readerEmptyStateIsAnActionableOnRamp() throws {
        let source = try Self.viewSource(named: "ReaderEmptyState.swift")
        let root = try Self.viewSource(named: "RootTabView.swift")
        let folderPicker = try Self.utilitySource(named: "FolderPicker.swift")

        #expect(
            source.contains(
                "Add an EPUB for searchable text, or a PDF for page-based reading and alignment.")
        )
        #expect(
            source.contains(
                "Choose an audiobook, EPUB, or transcript to start reading and studying."))
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

    @Test func missingBookFilesSurfaceRecovery() throws {
        let root = try Self.viewSource(named: "RootTabView.swift")

        #expect(root.contains("model.showingMissingBookWarning"))
        #expect(root.contains("may have moved or been deleted"))
        #expect(root.contains("Button(\"Choose Book\")"))
    }

    @Test func libraryEmptyStateIsActionFirst() throws {
        let landing = try Self.viewSource(named: "Library/LibraryView.swift")

        #expect(landing.contains("Your Library"))
        #expect(landing.contains("Add a folder of audiobooks"))
        #expect(landing.contains("Button(\"Open a Folder\", systemImage: \"folder\""))
        #expect(landing.contains("Connect a Server"))
        #expect(landing.contains("it never copies them"))
    }

    @Test func libraryEmptyStateAdaptsForLargestDynamicType() throws {
        let landing = try Self.viewSource(named: "Library/LibraryView.swift")

        #expect(
            landing.contains("LibraryEmptyState"),
            "The library empty state should own its adaptive layout instead of relying on ContentUnavailableView's fixed composition."
        )
        #expect(
            landing.contains("ScrollView"),
            "The empty state should scroll when accessibility Dynamic Type makes the title, copy, and actions taller than the viewport."
        )
        #expect(
            landing.contains("dynamicTypeSize.isAccessibilitySize"),
            "The empty state should branch layout for accessibility content sizes rather than capping Dynamic Type."
        )
        #expect(
            landing.contains("VStackLayout(spacing: 12)"),
            "The empty-state actions should reflow vertically at accessibility sizes so both buttons remain reachable."
        )
        #expect(
            landing.contains("bottomDockClearance"),
            "The empty state should reserve bottom clearance for the root-owned bottom dock."
        )
        #expect(
            landing.contains(".lineLimit(nil)")
                && landing.contains(".fixedSize(horizontal: false, vertical: true)"),
            "Empty-state text should grow vertically instead of being clipped or forced onto one line."
        )
        #expect(
            landing.contains(".frame(minHeight: 44)"),
            "The empty-state actions should keep at least 44pt touch targets."
        )
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
