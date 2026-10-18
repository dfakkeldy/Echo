// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AnthropicMessagesClientTests: XCTestCase {
    private func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testReturnsStructuredJSONText() async throws {
        let body = """
            {"stop_reason":"end_turn","content":[{"type":"text","text":"{\\"cards\\":[]}"}]}
            """.data(using: .utf8)!
        let client = AnthropicMessagesClient(apiKey: "sk", session: session { _ in (200, body) })
        let text = try await client.complete(
            systemPrompt: "s", userPrompt: "u", schema: ["type": "object"], maxTokens: 256)
        XCTAssertEqual(text, "{\"cards\":[]}")
    }

    func testMapsRefusal() async {
        let body =
            #"{"stop_reason":"refusal","stop_details":{"type":"refusal","explanation":"no"},"content":[]}"#
            .data(using: .utf8)!
        let client = AnthropicMessagesClient(apiKey: "sk", session: session { _ in (200, body) })
        await XCTAssertThrowsErrorAsync(
            try await client.complete(
                systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 256)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .refusal("no"))
        }
    }

    func testMapsUnauthorized() async {
        let c401 = AnthropicMessagesClient(
            apiKey: "sk", session: session { _ in (401, Data("{}".utf8)) })
        await XCTAssertThrowsErrorAsync(
            try await c401.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .unauthorized)
        }
    }

    func testMaps429WithRetryAfter() async {
        // Case 1: 429 with no retry-after header → retryAfter: nil
        StubURLProtocol.extraHeaders = [:]
        let cNoHeader = AnthropicMessagesClient(
            apiKey: "sk", session: session { _ in (429, Data()) })
        await XCTAssertThrowsErrorAsync(
            try await cNoHeader.complete(
                systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .rateLimited(retryAfter: nil))
        }

        // Case 2: 429 with retry-after: 30 header → retryAfter: 30
        StubURLProtocol.extraHeaders = ["retry-after": "30"]
        let cWithHeader = AnthropicMessagesClient(
            apiKey: "sk", session: session { _ in (429, Data()) })
        await XCTAssertThrowsErrorAsync(
            try await cWithHeader.complete(
                systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .rateLimited(retryAfter: 30))
        }
        StubURLProtocol.extraHeaders = [:]
    }

    func testSendsRequiredHeaders() async throws {
        let body = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{}"}]}"#.data(
            using: .utf8)!
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk-XYZ",
            session: session {
                captured = $0
                return (200, body)
            })
        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-api-key"), "sk-XYZ")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }
}
