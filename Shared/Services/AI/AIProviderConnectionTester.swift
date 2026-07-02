// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of Settings' Test Connection, with a user-facing message per case.
nonisolated enum AIProviderConnectionOutcome: Equatable, Sendable {
    case success
    case badToken
    case rateLimited
    case unreachable(String)
    case badStatus(Int)
    case unexpectedResponse

    var message: String {
        switch self {
        case .success:
            "Connection OK - the provider replied."
        case .badToken:
            "The provider rejected this token (401). Check the token."
        case .rateLimited:
            "Reachable but rate-limited (429) - the token works."
        case .unreachable(let detail):
            "Could not reach the endpoint: \(detail). Check the base URL."
        case .badStatus(let code):
            "Unexpected HTTP status \(code) - check the base URL and model."
        case .unexpectedResponse:
            "The endpoint replied, but not with a Messages API response."
        }
    }
}

/// Runs a minimal Messages call and classifies the result for Settings.
nonisolated struct AIProviderConnectionTester: Sendable {
    let client: AnthropicMessagesClient

    func test() async -> AIProviderConnectionOutcome {
        do {
            try await client.ping()
            return .success
        } catch let error as AnthropicClientError {
            switch error {
            case .unauthorized:
                return .badToken
            case .rateLimited:
                return .rateLimited
            case .transport(let detail):
                return .unreachable(detail)
            case .badStatus(let code):
                return .badStatus(code)
            case .refusal, .emptyContent, .invalidJSON:
                return .unexpectedResponse
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
