import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func testSentenceTokenization() {
    let processor = NLPProcessor()
    let sentences = processor.sentences(from: "Hello world. This is a test. Goodbye!")
    #expect(sentences.count == 3)
    #expect(sentences[0] == "Hello world.")
    #expect(sentences[1] == "This is a test.")
    #expect(sentences[2] == "Goodbye!")
}

@Test func testWordTokenization() {
    let processor = NLPProcessor()
    let words = processor.words(from: "Hello world. Goodbye.")
    let meaningful = words.filter { $0.rangeOfCharacter(from: .letters) != nil }
    #expect(meaningful == ["Hello", "world", "Goodbye"])
}

@Test func testEmptyInput() {
    let processor = NLPProcessor()
    #expect(processor.sentences(from: "") == [])
    #expect(processor.words(from: "") == [])
}

@Test func testSingleSentence() {
    let processor = NLPProcessor()
    let sentences = processor.sentences(from: "Just one sentence without period")
    #expect(sentences.count == 1)
}
