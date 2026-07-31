// SPDX-License-Identifier: GPL-3.0-or-later
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
}
