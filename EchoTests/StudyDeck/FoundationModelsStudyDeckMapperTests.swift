// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class FoundationModelsStudyDeckMapperTests: XCTestCase {
    func testBasicCardMapping() {
        let d = StudyDeckFMCardMapper.draft(
            sourceBlockID: "epub-bk-s0-b0",
            frontText: "What pumps blood?", backText: "The heart.", kind: "basic", clozeText: "",
            tags: ["anatomy"])
        XCTAssertEqual(d.id, "fm-epub-bk-s0-b0")
        XCTAssertEqual(d.kind, .basic)
        XCTAssertNil(d.clozeText)
        XCTAssertEqual(d.tags, ["generated", "on-device", "anatomy"])
    }
    func testClozeCardMappingCarriesClozeText() {
        let d = StudyDeckFMCardMapper.draft(
            sourceBlockID: "epub-bk-s0-b0",
            frontText: "", backText: "", kind: "cloze", clozeText: "The {{c1::heart}} pumps blood.",
            tags: [])
        XCTAssertEqual(d.kind, .cloze)
        XCTAssertEqual(d.clozeText, "The {{c1::heart}} pumps blood.")
    }
    func testUnknownKindFallsBackToBasic() {
        let d = StudyDeckFMCardMapper.draft(
            sourceBlockID: "x", frontText: "q", backText: "a", kind: "weird", clozeText: "",
            tags: [])
        XCTAssertEqual(d.kind, .basic)
        XCTAssertNil(d.clozeText)
    }
}
