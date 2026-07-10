// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct EditionMatcherTests {
    @Test func normalizedKeyIgnoresPunctuationCaseAndLeadingArticles() {
        #expect(
            EditionMatcher.normalizedKey(title: "The High-Conflict Couple!")
                == "high conflict couple")
        #expect(
            EditionMatcher.normalizedKey(title: "A  Tale_of Two Cities") == "tale of two cities")
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

    @Test func authorlessEditionJoinsSingleAuthoredGroup() {
        // A separately imported epub row (author nil) must pair with the tagged
        // audio edition when the title bucket has exactly one author.
        let groups = EditionMatcher.groups(for: [
            .init(id: "audio", title: "Dune", author: "Frank Herbert"),
            .init(id: "text", title: "The Dune", author: nil),
        ])

        #expect(groups["audio"] != nil)
        #expect(groups["audio"] == groups["text"])
    }

    @Test func authorlessEditionStaysUngroupedAmongCompetingAuthors() {
        // Two distinct authors share the title: per-author pairs still group,
        // but the author-less row is ambiguous and must never be guessed in.
        let groups = EditionMatcher.groups(for: [
            .init(id: "frost-audio", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "frost-text", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "plath", title: "Collected Poems", author: "Sylvia Plath"),
            .init(id: "orphan", title: "Collected Poems", author: nil),
        ])

        #expect(groups["frost-audio"] != nil)
        #expect(groups["frost-audio"] == groups["frost-text"])
        #expect(groups["plath"] == nil)
        #expect(groups["orphan"] == nil)
    }

    @Test func twoAuthorlessEditionsWithSameTitleGroup() {
        let groups = EditionMatcher.groups(for: [
            .init(id: "x", title: "The Dune", author: nil),
            .init(id: "y", title: "Dune", author: ""),
        ])

        #expect(groups["x"] != nil)
        #expect(groups["x"] == groups["y"])
    }

    @Test func singleBooksByDifferentAuthorsWithSameTitleStayUngrouped() {
        // One book per author on a shared title: no bucket has two members, so
        // author tolerance must not merge across authors.
        let groups = EditionMatcher.groups(for: [
            .init(id: "frost", title: "Collected Poems", author: "Robert Frost"),
            .init(id: "plath", title: "Collected Poems", author: "Sylvia Plath"),
        ])

        #expect(groups.isEmpty)
    }
}
