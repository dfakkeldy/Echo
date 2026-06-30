// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AnthropicClientError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case refusal(String?)
    case badStatus(Int)
    case emptyContent
    case transport(String)
}

/// Minimal hand-written Anthropic Messages API client (no official Swift SDK).
/// Structured output via output_config.format guarantees a single JSON object in the
/// assistant's text block. Adaptive thinking only; no sampling params.
nonisolated struct AnthropicMessagesClient: Sendable {
    let apiKey: String
    let model: String
    let session: URLSession

    nonisolated init(
        apiKey: String, model: String = "claude-opus-4-8", session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    nonisolated func complete(
        systemPrompt: String, userPrompt: String, schema: [String: Any], maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": ["type": "adaptive"],
            "system": [
                ["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [["role": "user", "content": userPrompt]],
            "output_config": [
                "effort": "medium", "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw AnthropicClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.transport("no response")
        }
        switch http.statusCode {
        case 200: break
        case 401: throw AnthropicClientError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicClientError.rateLimited(retryAfter: retry)
        default: throw AnthropicClientError.badStatus(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClientError.transport("non-JSON body")
        }
        if (json["stop_reason"] as? String) == "refusal" {
            let explanation = (json["stop_details"] as? [String: Any])?["explanation"] as? String
            throw AnthropicClientError.refusal(explanation)
        }
        let content = json["content"] as? [[String: Any]] ?? []
        guard
            let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"]
                as? String,
            !text.isEmpty
        else {
            throw AnthropicClientError.emptyContent
        }
        return text
    }
}
