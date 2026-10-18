// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class StudyDeckOutputValidationTests: XCTestCase {
    // MARK: - studyDeckHasValidClozeMarkers

    func testValidClozeMarker() {
        XCTAssertTrue(studyDeckHasValidClozeMarkers("The {{c1::mitochondria}} is the powerhouse."))
    }

    func testNoClozeMarkers() {
        XCTAssertFalse(studyDeckHasValidClozeMarkers("No deletions here."))
    }

    func testMissingC1Ordinal() {
        // Has c2 but no c1 — must be rejected
        XCTAssertFalse(studyDeckHasValidClozeMarkers("{{c2::only c2}}"))
    }

    func testUnbalancedClosingBrace() {
        // Stray }} before any opening marker → false
        XCTAssertFalse(studyDeckHasValidClozeMarkers("}} broken"))
    }

    func testMultipleMarkersBothC1() {
        XCTAssertTrue(studyDeckHasValidClozeMarkers("{{c1::alpha}} and {{c1::beta}}"))
    }

    func testC1AndC2Together() {
        XCTAssertTrue(studyDeckHasValidClozeMarkers("{{c1::front}} {{c2::back}}"))
    }

    func testEmptyString() {
        XCTAssertFalse(studyDeckHasValidClozeMarkers(""))
    }

    func testEmptyContentInsideMarker() {
        // Content part is whitespace-only → invalid
        XCTAssertFalse(studyDeckHasValidClozeMarkers("{{c1:: }}"))
    }

    // MARK: - studyDeckIsLongSourceQuotation

    /// Build a source whose first 14 words each ≥ 6 chars so the 14-word phrase exceeds 80 chars.
    private func longSource() -> String {
        // 14 words × ~6 chars + 13 spaces ≈ 97 chars for the phrase
        "antelope buffalo crimson dolphin elegant flannel genuine harmony ignite journey kitchen lantern muffin network orphan"
    }

    private func first14Words(of source: String) -> String {
        let words =
            source
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words.prefix(14).joined(separator: " ")
    }

    func testLongQuotationFlagged() {
        let source = longSource()
        let phrase = first14Words(of: source)
        XCTAssertGreaterThanOrEqual(
            phrase.count, 80, "Test prerequisite: phrase must be ≥ 80 chars")
        // Candidate embeds the verbatim 14-word normalized run
        let candidate = "Some intro. \(phrase). Some outro."
        XCTAssertTrue(studyDeckIsLongSourceQuotation([candidate], sourceText: source))
    }

    func testShortFragmentNotFlagged() {
        let source = longSource()
        // Candidate only copies 3 words — not a long quote
        let words = source.split(separator: " ").prefix(3).joined(separator: " ")
        XCTAssertFalse(studyDeckIsLongSourceQuotation([words], sourceText: source))
    }

    func testSourceUnder14WordsNotFlagged() {
        // Even if the candidate copies everything, source < 14 words → always false
        let shortSource = "one two three four five six seven eight nine ten eleven twelve thirteen"
        // 13 words
        let candidate = shortSource
        XCTAssertFalse(studyDeckIsLongSourceQuotation([candidate], sourceText: shortSource))
    }

    func testSourceExactly14WordsShortPhrase() {
        // 14 words but phrase is short (≤ 80 chars) → not flagged
        let source = "a b c d e f g h i j k l m n"  // 14 single-char words → phrase is 27 chars
        XCTAssertFalse(studyDeckIsLongSourceQuotation([source], sourceText: source))
    }

    func testEmptyCandidateListNotFlagged() {
        let source = longSource()
        XCTAssertFalse(studyDeckIsLongSourceQuotation([], sourceText: source))
    }
}
