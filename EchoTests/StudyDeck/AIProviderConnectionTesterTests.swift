// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AIProviderConnectionTesterTests: XCTestCase {
    private func client(_ handler: @escaping (URLRequest) -> (Int, Data)) -> AnthropicMessagesClient {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: config))
    }

    func testSuccessfulPingReportsSuccess() async {
        let ok = Data(
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"pong"}]}"#.utf8
        )
        let outcome = await AIProviderConnectionTester(client: client { _ in (200, ok) }).test()
        XCTAssertEqual(outcome, .success)
    }

    func test401ReportsBadToken() async {
        let outcome = await AIProviderConnectionTester(
            client: client { _ in (401, Data("{}".utf8)) }
        ).test()
        XCTAssertEqual(outcome, .badToken)
    }

    func test429ReportsRateLimitedNotFailure() async {
        let outcome = await AIProviderConnectionTester(client: client { _ in (429, Data()) }).test()
        XCTAssertEqual(outcome, .rateLimited)
    }

    func testWrongPathReportsBadStatus() async {
        let outcome = await AIProviderConnectionTester(client: client { _ in (404, Data()) }).test()
        XCTAssertEqual(outcome, .badStatus(404))
    }

    func testUnreachableHostReportsUnreachable() async {
        StubURLProtocol.reset()
        StubURLProtocol.transportError = URLError(.cannotFindHost)
        defer { StubURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let tester = AIProviderConnectionTester(
            client: AnthropicMessagesClient(apiKey: "sk", session: URLSession(configuration: config))
        )

        let outcome = await tester.test()

        guard case .unreachable = outcome else {
            return XCTFail("expected .unreachable, got \(outcome)")
        }
    }

    func testEmptyContentReportsUnexpectedResponse() async {
        let empty = Data(#"{"stop_reason":"end_turn","content":[]}"#.utf8)
        let outcome = await AIProviderConnectionTester(client: client { _ in (200, empty) }).test()
        XCTAssertEqual(outcome, .unexpectedResponse)
    }

    func testEveryOutcomeHasANonEmptyUserMessage() {
        let outcomes: [AIProviderConnectionOutcome] = [
            .success,
            .badToken,
            .rateLimited,
            .unreachable("x"),
            .badStatus(500),
            .unexpectedResponse,
        ]
        for outcome in outcomes {
            XCTAssertFalse(outcome.message.isEmpty)
        }
    }
}
