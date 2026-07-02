// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AnthropicClientDialectTests: XCTestCase {
    private let okBody = Data(
        #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"cards\":[]}"}]}"#.utf8
    )

    private func envelope(_ text: String) -> Data {
        let inner = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return Data(
            "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\(inner)}]}"
                .utf8
        )
    }

    private func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testFullDialectSendsThinkingAndOutputConfig() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            session: session {
                captured = $0
                return (200, self.okBody)
            }
        )

        _ = try await client.complete(
            systemPrompt: "sys",
            userPrompt: "user",
            schema: ["type": "object"],
            maxTokens: 64
        )

        let body = try XCTUnwrap(captured?.stubBodyJSON)
        XCTAssertNotNil(body["thinking"])
        XCTAssertNotNil(body["output_config"])
        XCTAssertTrue(body["system"] is [[String: Any]])
    }

    func testConservativeOmitsFeatureFieldsAndEmbedsSchemaInPrompt() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            capabilities: .conservative,
            session: session {
                captured = $0
                return (200, self.okBody)
            }
        )

        _ = try await client.complete(
            systemPrompt: "sys",
            userPrompt: "user",
            schema: ["type": "object"],
            maxTokens: 64
        )

        let body = try XCTUnwrap(captured?.stubBodyJSON)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["system"] as? String, "sys")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(content.hasPrefix("user"))
        XCTAssertTrue(content.contains("ONLY one JSON object"))
        XCTAssertTrue(content.contains(#"{"type":"object"}"#))
    }

    func testBearerAuthSendsExactlyOneCredentialHeader() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "tok-123",
            authStyle: .bearer,
            session: session {
                captured = $0
                return (200, self.okBody)
            }
        )

        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testXAPIKeyAuthSendsExactlyOneCredentialHeader() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "sk-XYZ",
            session: session {
                captured = $0
                return (200, self.okBody)
            }
        )

        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-api-key"), "sk-XYZ")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testBaseURLRoutesToCompatEndpoint() async throws {
        var captured: URLRequest?
        let client = AnthropicMessagesClient(
            apiKey: "tok",
            baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
            authStyle: .bearer,
            capabilities: .conservative,
            session: session {
                captured = $0
                return (200, self.okBody)
            }
        )

        _ = try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 1)

        XCTAssertEqual(
            captured?.url?.absoluteString,
            "https://api.deepseek.com/anthropic/v1/messages"
        )
    }

    func testConservativeExtractsFencedJSON() async throws {
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            capabilities: .conservative,
            session: session { _ in
                (200, self.envelope("Here you go:\n```json\n{\"cards\":[]}\n```"))
            }
        )

        let text = try await client.complete(
            systemPrompt: "s",
            userPrompt: "u",
            schema: [:],
            maxTokens: 8
        )

        XCTAssertEqual(text, "{\"cards\":[]}")
    }

    func testConservativeRetriesOnceThenSucceeds() async throws {
        var callCount = 0
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            capabilities: .conservative,
            session: session { _ in
                callCount += 1
                let text = callCount == 1 ? "I cannot produce JSON right now." : "{\"ok\":true}"
                return (200, self.envelope(text))
            }
        )

        let result = try await client.complete(
            systemPrompt: "s",
            userPrompt: "u",
            schema: [:],
            maxTokens: 8
        )

        XCTAssertEqual(result, "{\"ok\":true}")
        XCTAssertEqual(callCount, 2)
    }

    func testConservativeThrowsInvalidJSONAfterFailedRetry() async {
        var callCount = 0
        let client = AnthropicMessagesClient(
            apiKey: "sk",
            capabilities: .conservative,
            session: session { _ in
                callCount += 1
                return (200, self.envelope("still prose, no object"))
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await client.complete(systemPrompt: "s", userPrompt: "u", schema: [:], maxTokens: 8)
        ) {
            XCTAssertEqual($0 as? AnthropicClientError, .invalidJSON)
        }
        XCTAssertEqual(callCount, 2)
    }

    func testClientsFactoryBuildsBriefFromLightModel() throws {
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.lightModel = "deepseek-v4-flash"
        let pair = try XCTUnwrap(AnthropicMessagesClient.clients(config: config, token: "tok"))

        XCTAssertEqual(pair.primary.model, "deepseek-v4-pro[1m]")
        XCTAssertEqual(pair.brief.model, "deepseek-v4-flash")
        XCTAssertEqual(pair.primary.baseURL.absoluteString, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(pair.primary.authStyle, .bearer)
        XCTAssertEqual(pair.primary.apiKey, "tok")

        config.lightModel = nil
        let solo = try XCTUnwrap(AnthropicMessagesClient.clients(config: config, token: "tok"))
        XCTAssertEqual(solo.brief.model, "deepseek-v4-pro[1m]")
    }

    func testClientsFactoryRejectsInvalidBaseURL() {
        var config = AIProviderConfig.defaults(for: .custom)
        config.baseURL = "   "
        config.primaryModel = "m"
        XCTAssertNil(AnthropicMessagesClient.clients(config: config, token: "tok"))
    }
}
