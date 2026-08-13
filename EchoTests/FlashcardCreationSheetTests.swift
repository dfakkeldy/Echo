// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@MainActor
struct FlashcardCreationSheetTests {
    @Test func normalizedTagsReturnsNilForBlankInput() {
        #expect(FlashcardCreationSheet.normalizedTags(from: " \n\t ") == nil)
    }

    @Test func normalizedTagsTrimsOuterWhitespace() {
        #expect(FlashcardCreationSheet.normalizedTags(from: "  concept memory  ") == "concept memory")
    }
}
