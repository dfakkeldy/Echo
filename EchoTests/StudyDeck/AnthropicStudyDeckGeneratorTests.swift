// SPDX-License-Identifier: GPL-3.0-or-later
import Synchronization
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
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let gen = AnthropicStudyDeckGenerator(
            client: AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: cfg)))
        let draft = await gen.generate(sources: [source("epub-bk-s0-b0")], settings: .init())
        XCTAssertTrue(draft.cards.isEmpty)
    }

    // MARK: - Two-pass helpers (Task 2.4)

    /// A source on a given spine index so the batcher splits across spines/batches.
    private func source(_ id: String, spine: Int, text: String? = nil) -> StudyDeckSource {
        StudyDeckSource(
            id: id, sourceBlockID: id, audiobookID: "bk", blockKind: "p",
            text: text ?? "Body text for \(id).",
            chapterIndex: 0, sequenceIndex: spine, spineIndex: spine, blockIndex: 0)
    }

    /// Wraps an inner JSON object string in the Anthropic content envelope as a 200 response.
    private func ok(_ json: String) -> (Int, Data) {
        (
            200,
            Data(
                "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\(jsonEncoded(json))}]}"
                    .utf8)
        )
    }

    /// Client wired to the sequential `responses` queue (brief, then per batch).
    private func queuedClient(_ responses: [(Int, Data)]) -> AnthropicMessagesClient {
        StubURLProtocol.reset()
        StubURLProtocol.responses = responses
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: cfg))
    }

    private static let briefJSON =
        #"{"summary":"s","themes":["t"],"keyConcepts":["k"]}"#

    // MARK: - Two-pass tests (Task 2.4)

    @MainActor
    func testAccumulatesCardsAcrossBatches() async {
        // 13 sources across two spines → batch size 12 yields ≥2 batches.
        var sources = (0..<12).map { source("b\($0)", spine: 0) }
        sources.append(source("b12", spine: 1))

        let client = queuedClient([
            ok(Self.briefJSON),  // brief pass
            ok(#"{"cards":[{"sourceBlockID":"b0","frontText":"Q0","backText":"A0"}]}"#),  // batch 1
            ok(#"{"cards":[{"sourceBlockID":"b12","frontText":"Q12","backText":"A12"}]}"#),  // batch 2
        ])
        let progress = Mutex<[(Int, Int)]>([])
        let gen = AnthropicStudyDeckGenerator(client: client) { done, total in
            progress.withLock { $0.append((done, total)) }
        }

        let draft = await gen.generate(sources: sources, settings: .init())

        let ids = Set(draft.cards.map(\.sourceBlockID))
        XCTAssertTrue(ids.contains("b0"), "batch 1 card missing")
        XCTAssertTrue(ids.contains("b12"), "batch 2 card missing")
        XCTAssertEqual(draft.cards.count, 2)
        // Progress reports (1,2) then (2,2).
        XCTAssertEqual(progress.withLock { $0.map(\.0) }, [1, 2])
        XCTAssertEqual(progress.withLock { $0.allSatisfy { $0.1 == 2 } }, true)
    }

    @MainActor
    func testPartialRecoveryKeepsEarlierBatchOn500() async {
        var sources = (0..<12).map { source("b\($0)", spine: 0) }
        sources.append(source("b12", spine: 1))

        let client = queuedClient([
            ok(Self.briefJSON),  // brief pass OK
            ok(#"{"cards":[{"sourceBlockID":"b0","frontText":"Q0","backText":"A0"}]}"#),  // batch 1 OK
            (500, Data("{}".utf8)),  // batch 2 fails
        ])
        let gen = AnthropicStudyDeckGenerator(client: client)

        let draft = await gen.generate(sources: sources, settings: .init())

        XCTAssertEqual(
            draft.cards.map(\.sourceBlockID), ["b0"], "batch 1 card must survive batch 2 failure")
    }

    @MainActor
    func testBriefFailureStillProducesCards() async {
        let sources = [source("b0", spine: 0)]
        let client = queuedClient([
            (500, Data("{}".utf8)),  // brief pass fails → proceed with empty brief
            ok(#"{"cards":[{"sourceBlockID":"b0","frontText":"Q0","backText":"A0"}]}"#),  // batch 1 OK
        ])
        let gen = AnthropicStudyDeckGenerator(client: client)

        let draft = await gen.generate(sources: sources, settings: .init())

        XCTAssertEqual(draft.cards.map(\.sourceBlockID), ["b0"])
    }

    @MainActor
    func testDropsLongSourceQuotation() async {
        let quote =
            "Synthetic retrieval practice strengthens recall across spaced sessions and helps every learner remember concepts."
        let sources = [source("b0", spine: 0, text: quote)]
        // Front copies the verbatim source quote (≥14 words, ≥80 chars) → dropped.
        let card =
            "{\"cards\":[{\"sourceBlockID\":\"b0\",\"frontText\":\(jsonEncoded(quote)),\"backText\":\"A\"}]}"
        let client = queuedClient([
            ok(Self.briefJSON),  // brief
            ok(card),  // batch 1
        ])
        let gen = AnthropicStudyDeckGenerator(client: client)

        let draft = await gen.generate(sources: sources, settings: .init())

        XCTAssertTrue(draft.cards.isEmpty, "verbatim long-quote card must be dropped")
    }

    @MainActor
    func testCancellationReturnsPartialDraft() async {
        var sources = (0..<12).map { source("b\($0)", spine: 0) }
        sources.append(source("b12", spine: 1))

        let client = queuedClient([
            ok(Self.briefJSON),  // brief
            ok(#"{"cards":[{"sourceBlockID":"b0","frontText":"Q0","backText":"A0"}]}"#),  // batch 1
            ok(#"{"cards":[{"sourceBlockID":"b12","frontText":"Q12","backText":"A12"}]}"#),  // batch 2 (should not run)
        ])
        let gen = AnthropicStudyDeckGenerator(client: client)

        // Cancel the surrounding task before generate starts batching its loop.
        let task = Task {
            await gen.generate(sources: sources, settings: .init())
        }
        task.cancel()
        let draft = await task.value

        // Either no cards (cancelled before batch 1) or only batch-1 cards — never crashes,
        // and never includes batch-2 cards because the loop stops at cancellation.
        XCTAssertFalse(
            draft.cards.map(\.sourceBlockID).contains("b12"),
            "cancellation must stop the batch loop before batch 2")
    }
}
