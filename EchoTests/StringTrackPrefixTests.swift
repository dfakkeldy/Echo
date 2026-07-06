// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct StringTrackPrefixTests {
    @Test func stripsPlainNumericTrackPrefixes() {
        #expect("001 The Long Road".strippingTrackNumberPrefix() == "The Long Road")
        #expect("12. Chapter Twelve".strippingTrackNumberPrefix() == "Chapter Twelve")
        #expect("03 - A Door Opens".strippingTrackNumberPrefix() == "A Door Opens")
    }

    @Test func stripsTrackKeywordPrefixes() {
        #expect("Track 04: Arrivals".strippingTrackNumberPrefix() == "Arrivals")
        #expect("Chapter 7 - The Bridge".strippingTrackNumberPrefix() == "The Bridge")
    }

    @Test func preservesSemanticTitlesAndEmptyResults() {
        #expect("1984".strippingTrackNumberPrefix() == "1984")
        #expect("Chapter House Dune".strippingTrackNumberPrefix() == "Chapter House Dune")
        #expect("01".strippingTrackNumberPrefix() == "01")
    }
}
