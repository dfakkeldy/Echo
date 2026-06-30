// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AnthropicStudyDeckGeneratorTests: XCTestCase {
    private func source(_ id: String) -> StudyDeckSource {
        StudyDeckSource(
            id: id, sourceBlockID: id, audiobookID: "bk", blockKind: "p",
            text: "The mitochondria is the powerhouse of the cell.",
            chapterIndex: 0, sequenceIndex: 0, spineIndex: 0, blockIndex: 0)
    }

    private func client(_ json: String) -> AnthropicMessagesClient {
        let encoded = jsonEncoded(json)
        StubURLProtocol.handler = { _ in
            (
                200,
                Data(
                    "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\(encoded)}]}"
                        .utf8)
            )
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: cfg))
    }

    // helper: encode the inner JSON as a JSON string literal
    private func jsonEncoded(_ s: String) -> String {
        String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
    }

    @MainActor
    func testMapsValidCards() async {
        let gen = AnthropicStudyDeckGenerator(
            client: client(
                #"{"cards":[{"sourceBlockID":"epub-bk-s0-b0","frontText":"What is the powerhouse of the cell?","backText":"The mitochondria."}]}"#
            ))
        let draft = await gen.generate(sources: [source("epub-bk-s0-b0")], settings: .init())
        XCTAssertEqual(draft.cards.count, 1)
        XCTAssertEqual(draft.cards.first?.sourceBlockID, "epub-bk-s0-b0")
        XCTAssertEqual(draft.cards.first?.tags, ["generated", "ai"])
    }

    @MainActor
    func testDropsHallucinatedBlockID() async {
        let gen = AnthropicStudyDeckGenerator(
            client: client(
                #"{"cards":[{"sourceBlockID":"epub-bk-s9-b9","frontText":"Q","backText":"A"}]}"#))
        let draft = await gen.generate(sources: [source("epub-bk-s0-b0")], settings: .init())
        XCTAssertTrue(draft.cards.isEmpty)  // GeneratedStudyDeckDraft validation drops unknown id
    }

    @MainActor
    func testReturnsEmptyDraftOnError() async {
        StubURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let gen = AnthropicStudyDeckGenerator(
            client: AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: cfg)))
        let draft = await gen.generate(sources: [source("epub-bk-s0-b0")], settings: .init())
        XCTAssertTrue(draft.cards.isEmpty)
    }
}
