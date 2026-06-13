import Testing
import Foundation
@testable import Echo

struct ClozeParserTests {

    // MARK: - hasClozeDeletions

    @Test func detectsClozeDeletions() {
        #expect(ClozeParser.hasClozeDeletions("{{c1::mitosis}}"))
        #expect(ClozeParser.hasClozeDeletions("{{c2::cell division}}"))
        #expect(ClozeParser.hasClozeDeletions("{{c10::long answer}}"))
    }

    @Test func rejectsTextWithoutCloze() {
        #expect(!ClozeParser.hasClozeDeletions(""))
        #expect(!ClozeParser.hasClozeDeletions("plain text"))
        #expect(!ClozeParser.hasClozeDeletions("{c1::no curly}}"))
    }

    // MARK: - parseDeletions

    @Test func parsesSingleClozeDeletion() throws {
        let deletions = ClozeParser.parseDeletions("{{c1::mitosis}}")
        #expect(deletions.count == 1)
        let d = try #require(deletions.first)
        #expect(d.index == 1)
        #expect(d.answer == "mitosis")
    }

    @Test func parsesMultipleClozeDeletions() throws {
        let deletions = ClozeParser.parseDeletions(
            "{{c1::mitosis}} is the process of {{c2::cell division}}"
        )
        #expect(deletions.count == 2)

        let c1 = try #require(deletions.first)
        #expect(c1.index == 1)
        #expect(c1.answer == "mitosis")

        let c2 = try #require(deletions.last)
        #expect(c2.index == 2)
        #expect(c2.answer == "cell division")
    }

    @Test func ignoresMalformedCloze() {
        let deletions = ClozeParser.parseDeletions(
            "{{c1::valid}} {{c2broken}} {{cinvalid}} {{c3::too::many::colons}}"
        )
        // Only the well-formed one should parse.
        // "{{c3::too::many::colons}}" has colons in the answer text,
        // so the split on "::" may produce unexpected results.
        // The regex pattern `[^}]+` captures up to the first `}}`,
        // so `{{c3::too::many::colons}}` would match with answer "too::many::colons".
        #expect(deletions.count == 2)
        #expect(deletions[0].index == 1)
        #expect(deletions[0].answer == "valid")
        #expect(deletions[1].index == 3)
    }

    @Test func returnsEmptyArrayForNoCloze() {
        #expect(ClozeParser.parseDeletions("").isEmpty)
        #expect(ClozeParser.parseDeletions("plain text").isEmpty)
    }

    // MARK: - makeFront

    @Test func makeFrontReplacesWithPlaceholder() throws {
        let deletions = ClozeParser.parseDeletions("{{c1::mitosis}} happens")
        let d = try #require(deletions.first)
        let front = ClozeParser.makeFront(text: "{{c1::mitosis}} happens", deletion: d)
        #expect(front == "[...] happens")
    }

    @Test func makeFrontMultipleOnlyBlanksOne() throws {
        let text = "{{c1::mitosis}} and {{c2::meiosis}}"
        let deletions = ClozeParser.parseDeletions(text)
        #expect(deletions.count == 2)

        let front1 = ClozeParser.makeFront(text: text, deletion: deletions[0])
        #expect(front1 == "[...] and {{c2::meiosis}}")

        let front2 = ClozeParser.makeFront(text: text, deletion: deletions[1])
        #expect(front2 == "{{c1::mitosis}} and [...]")
    }

    // MARK: - makeBack

    @Test func makeBackReplacesWithHighlightedAnswer() throws {
        let deletions = ClozeParser.parseDeletions("{{c1::mitosis}} happens")
        let d = try #require(deletions.first)
        let back = ClozeParser.makeBack(text: "{{c1::mitosis}} happens", deletion: d)
        #expect(back == "[mitosis] happens")
    }

    @Test func makeBackMultipleOnlyRevealsOne() throws {
        let text = "{{c1::mitosis}} and {{c2::meiosis}}"
        let deletions = ClozeParser.parseDeletions(text)

        let back1 = ClozeParser.makeBack(text: text, deletion: deletions[0])
        #expect(back1 == "[mitosis] and {{c2::meiosis}}")

        let back2 = ClozeParser.makeBack(text: text, deletion: deletions[1])
        #expect(back2 == "{{c1::mitosis}} and [meiosis]")
    }

    // MARK: - Edge cases

    @Test func handlesEmptyString() {
        #expect(ClozeParser.parseDeletions("").isEmpty)
        #expect(!ClozeParser.hasClozeDeletions(""))
    }

    @Test func handlesAnswerWithSpaces() throws {
        let deletions = ClozeParser.parseDeletions("{{c1::cell division}}")
        let d = try #require(deletions.first)
        #expect(d.answer == "cell division")
    }

    @Test func handlesLargeIndex() throws {
        let deletions = ClozeParser.parseDeletions("{{c99::mitosis}}")
        let d = try #require(deletions.first)
        #expect(d.index == 99)
        #expect(d.answer == "mitosis")
    }
}
