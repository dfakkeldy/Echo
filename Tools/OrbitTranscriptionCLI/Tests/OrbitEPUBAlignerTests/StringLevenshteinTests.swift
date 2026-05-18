import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func levenshteinIdenticalStrings() {
    let distance = "hello world".levenshteinDistance(to: "hello world")
    #expect(distance == 0)
}

@Test func levenshteinOneSubstitution() {
    let distance = "hello world".levenshteinDistance(to: "hello worle")
    #expect(distance == 1)
}

@Test func levenshteinCompletelyDifferent() {
    let distance = "abc".levenshteinDistance(to: "xyz")
    #expect(distance == 3)
}

@Test func levenshteinEmptyStrings() {
    #expect("".levenshteinDistance(to: "") == 0)
    #expect("abc".levenshteinDistance(to: "") == 3)
    #expect("".levenshteinDistance(to: "abc") == 3)
}

@Test func normalizedLevenshteinSimilarity() {
    let similarity = "hello world".normalizedLevenshteinSimilarity(to: "hello world")
    #expect(similarity == 1.0)

    let lowSimilarity = "abc".normalizedLevenshteinSimilarity(to: "xyz")
    #expect(lowSimilarity == 0.0)

    let partial = "hello world".normalizedLevenshteinSimilarity(to: "hello worle")
    #expect(abs(partial - 0.909) < 0.01)
}
