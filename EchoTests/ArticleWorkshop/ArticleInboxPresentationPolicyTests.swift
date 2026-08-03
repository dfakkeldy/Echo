// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleInboxPresentationPolicyTests {
    @Test func modePickerAdaptsAtAccessibilitySizesWithoutChangingAvailableModes() {
        #expect(
            LibraryModePickerPolicy.presentation(isAccessibilitySize: false) == .segmented)
        #expect(
            LibraryModePickerPolicy.presentation(isAccessibilitySize: true) == .menu)
        #expect(LibraryModePickerPolicy.availableModes == [.books, .inbox, .anthologies])
    }

    @Test func duplicateWarningTextKeepsDistinctOccurrenceIdentity() {
        let item = ArticleInboxItem(
            id: "capture-1",
            title: "Article",
            author: nil,
            siteName: nil,
            sourceURL: "https://example.com/article",
            canonicalURL: nil,
            capturedAt: "2026-07-28T12:01:00Z",
            state: .reviewSuggested,
            warnings: ["Image unavailable", "Image unavailable"],
            isPossibleDuplicate: false,
            keepBothAvailable: true
        )

        #expect(item.warningOccurrences.map(\.id) == [0, 1])
        #expect(
            item.warningOccurrences.map(\.text) == [
                "Image unavailable", "Image unavailable",
            ])
    }

    @Test func usedCaptureViewIsDiscoverableOnSharedAndMacInboxSurfaces() throws {
        let shared = try source(named: "EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift")
        let mac = try source(named: "Echo macOS/Views/MacArticleWorkshopView.swift")

        #expect(shared.contains("Show Used Captures"))
        #expect(mac.contains("Show Used Captures"))
        #expect(shared.contains("Used in EPUB"))
        #expect(mac.contains("Used in EPUB"))
    }

    @Test func successfulBuildRefreshesSharedAndMacInboxPresentations() throws {
        let detail = try source(named: "EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift")
        let library = try source(named: "EchoCore/Views/Library/LibraryView.swift")
        let mac = try source(named: "Echo macOS/Views/MacArticleWorkshopView.swift")

        #expect(detail.contains("await onSuccessfulBuild()"))
        #expect(library.contains("await articleInboxViewModel.reload()"))
        #expect(mac.contains("await inbox.reload()"))
    }

    private func source(named relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8)
    }
}
