// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct EditionMatcherTests {
    @Test func normalizedKeyIgnoresPunctuationCaseAndLeadingArticles() {
        #expect(EditionMatcher.normalizedKey(title: "The High-Conflict Couple!") == "high conflict couple")
        #expect(EditionMatcher.normalizedKey(title: "A  Tale_of Two Cities") == "tale of two cities")
    }

    @Test func groupsOnlyMatchingTitleAndAuthorPairs() {
        let groups = EditionMatcher.groups(for: [
            .init(id: "audio", title: "The High-Conflict Couple", author: "Alan Fruzzetti"),
            .init(id: "text", title: "High Conflict Couple", author: "Alan Fruzzetti"),
            .init(id: "other-author", title: "High Conflict Couple", author: "Other Author"),
            .init(id: "single", title: "Dune", author: "Frank Herbert"),
        ])

        #expect(groups["audio"] == groups["text"])
        #expect(groups["other-author"] == nil)
        #expect(groups["single"] == nil)
    }
}
