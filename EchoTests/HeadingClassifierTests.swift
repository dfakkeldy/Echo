// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

/// Tests for the unified junk-heading classifier. Import, the reader feed,
/// and the TOC sheet previously each had their own divergent copy of these
/// rules; they must all agree on one implementation.
struct HeadingClassifierTests {

    @Test(arguments: [
        "Cover",
        "Title Page",
        "Copyright",
        "Contents",
        "Table of Contents",
        "Praise for the second edition of The Pragmatic Programmer",
        "Also by David Thomas",
        "Dedication",
        "Index",
        "Bibliography",
    ])
    func nonContentHeadingsAreClassified(text: String) {
        #expect(HeadingClassifier.isNonContent(text))
    }

    @Test(arguments: [
        "Foreword",
        "Introduction",
        "Preface to the Second Edition",
        "Chapter 1 A Pragmatic Philosophy",
        "Team Trust",
        "What Is Orthogonality?",
    ])
    func contentHeadingsAreKept(text: String) {
        #expect(!HeadingClassifier.isNonContent(text))
    }

    @Test func junkCombinesUtilityLengthFigureAndNonContent() {
        #expect(HeadingClassifier.isJunk("Tip"))
        #expect(HeadingClassifier.isJunk("Warning"))
        #expect(HeadingClassifier.isJunk("Figure 2.1 The cost of change"))
        #expect(HeadingClassifier.isJunk(String(repeating: "x", count: 101)))
        #expect(HeadingClassifier.isJunk("Copyright"))
        #expect(!HeadingClassifier.isJunk("Chapter 1 A Pragmatic Philosophy"))
        #expect(!HeadingClassifier.isJunk("Foreword"))
    }
}
