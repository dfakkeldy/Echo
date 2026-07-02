// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AnthropicClientError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case refusal(String?)
    case badStatus(Int)
    case emptyContent
    /// Conservative dialect only: no valid JSON object could be extracted after retry.
    case invalidJSON
    case transport(String)
}

/// Minimal hand-written Anthropic Messages API client, pointable at compatible
/// endpoints via base URL, auth style, and capability-driven request dialect.
nonisolated struct AnthropicMessagesClient: Sendable {
    let apiKey: String
    let model: String
    let baseURL: URL
    let authStyle: AIProviderAuthStyle
    let capabilities: AIProviderCapabilities
    let session: URLSession

    nonisolated init(
        apiKey: String,
        model: String = "claude-opus-4-8",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        authStyle: AIProviderAuthStyle = .xAPIKey,
        capabilities: AIProviderCapabilities = .full,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.authStyle = authStyle
        self.capabilities = capabilities
        self.session = session
    }

    /// Builds the primary/brief client pair for a provider config. The brief client
    /// uses `lightModel` when present, otherwise it is the primary client.
    static func clients(
        config: AIProviderConfig,
        token: String,
        session: URLSession = .shared
    ) -> (primary: AnthropicMessagesClient, brief: AnthropicMessagesClient)? {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }

        func make(_ model: String) -> AnthropicMessagesClient {
            AnthropicMessagesClient(
                apiKey: token,
                model: model,
                baseURL: url,
                authStyle: config.authStyle,
                capabilities: config.capabilities,
                session: session
            )
        }

        let primary = make(config.primaryModel)
        let light = config.lightModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (primary, light.isEmpty ? primary : make(light))
    }

    nonisolated func complete(
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any],
        maxTokens: Int
    ) async throws -> String {
        if capabilities.supportsStructuredOutput {
            return try await performMessages(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schema: schema,
                maxTokens: maxTokens
            )
        }

        let prompt = userPrompt + Self.jsonOnlyInstruction(schema: schema)
        let first = try await performMessages(
            systemPrompt: systemPrompt,
            userPrompt: prompt,
            schema: nil,
            maxTokens: maxTokens
        )
        if let object = LooseJSONExtractor.firstJSONObject(in: first) {
            return object
        }

        let retryPrompt =
            prompt
            + "\n\nYour previous reply was not a single valid JSON object. "
            + "Reply again with ONLY the JSON object - no prose, no markdown fences."
        let second = try await performMessages(
            systemPrompt: systemPrompt,
            userPrompt: retryPrompt,
            schema: nil,
            maxTokens: maxTokens
        )
        if let object = LooseJSONExtractor.firstJSONObject(in: second) {
            return object
        }
        throw AnthropicClientError.invalidJSON
    }

    /// Minimal Messages call for Settings' Test Connection.
    nonisolated func ping() async throws {
        _ = try await performMessages(
            systemPrompt: "You are a connectivity check.",
            userPrompt: "Reply with the single word: pong",
            schema: nil,
            maxTokens: 16
        )
    }

    private nonisolated func performMessages(
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any]?,
        maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        switch authStyle {
        case .xAPIKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        if capabilities.supportsThinking {
            body["thinking"] = ["type": "adaptive"]
        }
        if let schema {
            body["system"] = [
                ["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]
            ]
            body["output_config"] = [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ]
        } else {
            body["system"] = systemPrompt
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.transport("no response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw AnthropicClientError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicClientError.rateLimited(retryAfter: retry)
        default:
            throw AnthropicClientError.badStatus(http.statusCode)
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

    /// Conservative-dialect instruction with deterministic schema ordering for tests.
    static nonisolated func jsonOnlyInstruction(schema: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let schemaText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "\n\nRespond with ONLY one JSON object - no prose, no markdown fences, "
            + "no explanations. The object must validate against this JSON schema:\n"
            + schemaText
    }
}
