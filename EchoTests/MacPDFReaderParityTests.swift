// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for the macOS PDF page-view reader. The `Echo macOS` target
/// is not compiled into EchoTests, so we assert against source text via
/// `MacSource`. The view reuses the shared, macOS-clean `PDFReadAlongController`
/// (no UIKit; already part of this target) for all timeline/page resolution.
struct MacPDFReaderParityTests {

    @Test func reusesSharedReadAlongController() throws {
        let src = try MacSource.read("Views/MacPDFReaderView.swift")
        #expect(
            src.contains("PDFReadAlongController()"),
            "The page view must drive the shared PDFReadAlongController, not duplicate its caching."
        )
        #expect(
            src.contains("readAlong.load(audiobookID:") && src.contains("readAlong.activeBlock(at:")
                && src.contains("readAlong.pageIndex(forBlock:"),
            "The page view must load and query the read-along caches for page auto-follow.")
    }

    @Test func autoFollowsOnlyWhilePlaying() throws {
        let src = try MacSource.read("Views/MacPDFReaderView.swift")
        #expect(
            src.contains("if isPlaying, let pageIndex = activePageIndex"),
            "Auto-follow must be gated on isPlaying so it never fights manual scrolling while paused."
        )
    }

    @Test func highlightsViaBuiltInPDFKitAPI() throws {
        let src = try MacSource.read("Views/MacPDFReaderView.swift")
        #expect(
            src.contains("highlightedSelections"),
            "Word highlight must use PDFView's built-in highlightedSelections, not a hand-rolled overlay."
        )
    }

    @Test func highlightAdvancesThroughRepeatedWordsAndIsThrottled() throws {
        let src = try MacSource.read("Views/MacPDFReaderView.swift")
        #expect(
            src.contains("highlightPositionKey"),
            "Highlighting must key off the word's position, not just its text — plain words recur on a page."
        )
        #expect(
            src.contains("fromSelection: resumeFrom"),
            "A repeated occurrence of the same word must search forward from the previous match.")
        #expect(
            src.contains("positionKey == lastHighlightPositionKey")
                && src.contains("currentPage === lastHighlightPage"),
            "The search must be skipped when the word position hasn't changed since the last call.")
    }

    @Test func contextMenuOffersLookUpAndSaveVocabulary() throws {
        let src = try MacSource.read("Views/MacPDFReaderView.swift")
        #expect(
            src.contains("showDefinition(for:"),
            "Look Up must use the system Dictionary popover (NSView.showDefinition).")
        #expect(
            src.contains("VocabularyCardBuilder.make(") && src.contains("FlashcardDAO(db:"),
            "Save as Flashcard must build a vocabulary card via the shared builder + DAO.")
        #expect(
            src.contains("vocabularyCard(for:") || src.contains(".vocabularyCard("),
            "Save as Flashcard must dedupe against an existing vocabulary card for the same word.")
    }

    @Test func readerOffersReflowPageToggle() throws {
        let src = try MacSource.read("Views/MacReaderFeedView.swift")
        #expect(
            src.contains("PDFBlockPageDAO(db:") && src.contains("hasPDFPages"),
            "MacReaderFeedView must detect source-PDF page data to gate the Reflow/Page toggle.")
        #expect(
            src.contains("MacPDFReaderView()"),
            "MacReaderFeedView must present MacPDFReaderView when Page view is selected.")
    }
}
