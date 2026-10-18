// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct PDFWordHighlightSearchTests {
    @Test func advancesThroughRepeatedTermsOnCurrentPage() throws {
        let text = "the first the second the third"

        let first = try #require(PDFWordHighlightSearch.range(for: "the", in: text, after: nil))
        let second = try #require(PDFWordHighlightSearch.range(for: "the", in: text, after: first))
        let third = try #require(PDFWordHighlightSearch.range(for: "the", in: text, after: second))

        #expect((text as NSString).substring(with: first) == "the")
        #expect((text as NSString).substring(with: second) == "the")
        #expect((text as NSString).substring(with: third) == "the")
        #expect(first.location == 0)
        #expect(second.location > first.location)
        #expect(third.location > second.location)
    }

    @Test func wrapsToFirstMatchWhenPreviousRangeIsPastLastTerm() throws {
        let text = "AI changes how teams use AI tools."
        let lastRange = NSRange(location: (text as NSString).length, length: 0)

        let wrapped = try #require(
            PDFWordHighlightSearch.range(for: "AI", in: text, after: lastRange))

        #expect(wrapped.location == 0)
        #expect((text as NSString).substring(with: wrapped) == "AI")
    }

    @Test func matchesBoundaryPunctuationUsingCanonicalDictionaryTerm() throws {
        let text = "Planning matters. Testing matters."

        let range = try #require(
            PDFWordHighlightSearch.range(for: "matters", in: text, after: nil))

        #expect((text as NSString).substring(with: range) == "matters.")
    }
}
