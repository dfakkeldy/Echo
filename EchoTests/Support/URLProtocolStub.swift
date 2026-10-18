// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A `URLProtocol` that returns canned responses keyed by URL path suffix.
/// Register a session via `URLProtocolStub.makeSession(scope:)` and stub responses
/// with `URLProtocolStub.stub(scope:pathSuffix:status:json:)`.
///
/// Every entry point takes an explicit `scope` on purpose. Swift Testing runs
/// suites — and the tests within a suite — concurrently in a single process, so
/// state keyed on anything shared is state two tests can overwrite for each
/// other. Give each test a fresh scope (see the `*Fixture` classes in the ABS
/// suites) rather than reaching for a common one.
// `nonisolated`: a `URLProtocol` subclass whose overrides (`canInit`, `startLoading`,
// etc.) must match URLProtocol's nonisolated isolation. Under Swift 6 MainActor
// default isolation the class would otherwise be inferred `@MainActor`, mismatching
// every override. (URLProtocol drives these on URLSession's loading threads.)
nonisolated final class URLProtocolStub: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
        var suspended: Bool
    }

    /// Bucket for traffic that did not come from `makeSession(scope:)` and so
    /// carries no scope header. No test reads it; it exists so an unrouted
    /// request is parked somewhere inert instead of landing in a real scope.
    private static let unroutedScope = "unrouted"
    private static let scopeHeader = "X-Echo-URLProtocolStub-Scope"
    private static let lock = NSLock()
    private let deliveryState = DeliveryState()
    nonisolated(unsafe) private static var responses: [String: [String: Response]] = [:]
    nonisolated(unsafe) private static var queryResponses: [QueryResponse] = []
    nonisolated(unsafe) private static var scopedRequests: [(String, URLRequest)] = []
    nonisolated(unsafe) private static var pending: [PendingResponse] = []

    static func requests(scope: String) -> [URLRequest] {
        lock.withLock { scopedRequests.compactMap { $0.0 == scope ? $0.1 : nil } }
    }

    static func pendingResponseCount(scope: String) -> Int {
        lock.withLock { pending.count { $0.scope == scope } }
    }

    private struct QueryResponse {
        var scope: String
        var pathSuffix: String
        var queryItems: [String: String]
        var response: Response
    }

    private struct PendingResponse {
        let stub: URLProtocolStub
        let scope: String
        let path: String
        let queryValues: [String: String]
        let response: Response
    }

    private final class DeliveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var deliveryClaimed = false

        func canRegisterPendingResponse() -> Bool {
            lock.withLock { !stopped && !deliveryClaimed }
        }

        func claimDelivery() -> Bool {
            lock.withLock {
                guard !stopped, !deliveryClaimed else { return false }
                deliveryClaimed = true
                return true
            }
        }

        func stop() {
            lock.withLock { stopped = true }
        }
    }

    static func reset(scope: String) {
        lock.withLock {
            responses[scope] = [:]
            queryResponses.removeAll { $0.scope == scope }
            scopedRequests.removeAll { $0.0 == scope }
            pending.removeAll { $0.scope == scope }
        }
    }

    static func finish(scope: String) {
        lock.withLock {
            responses.removeValue(forKey: scope)
            queryResponses.removeAll { $0.scope == scope }
            scopedRequests.removeAll { $0.0 == scope }
            pending.removeAll { $0.scope == scope }
        }
    }

    static func stub(
        scope: String, pathSuffix: String, status: Int = 200, json: String,
        headers: [String: String] = [:], suspended: Bool = false
    ) {
        stub(
            scope: scope, pathSuffix: pathSuffix, status: status, data: Data(json.utf8),
            headers: headers, suspended: suspended)
    }

    static func stub(
        scope: String, pathSuffix: String, status: Int = 200, data: Data,
        headers: [String: String] = [:], suspended: Bool = false
    ) {
        lock.withLock {
            var scoped = responses[scope] ?? [:]
            scoped[pathSuffix] = Response(
                status: status, body: data, headers: headers, suspended: suspended)
            responses[scope] = scoped
        }
    }

    static func stub(
        scope: String, pathSuffix: String, queryItems: [String: String],
        status: Int = 200, json: String, headers: [String: String] = [:],
        suspended: Bool = false
    ) {
        lock.withLock {
            queryResponses.append(
                QueryResponse(
                    scope: scope, pathSuffix: pathSuffix, queryItems: queryItems,
                    response: Response(
                        status: status, body: Data(json.utf8), headers: headers,
                        suspended: suspended)))
        }
    }

    static func resume(
        scope: String, pathSuffix: String, queryItems: [String: String] = [:],
        afterRemoval: ((URLProtocolStub) -> Void)? = nil
    ) {
        let matches = lock.withLock { () -> [PendingResponse] in
            let matches = pending.filter { pendingResponse in
                pendingResponse.scope == scope && pendingResponse.path.hasSuffix(pathSuffix)
                    && queryItems.allSatisfy { queryItem in
                        pendingResponse.queryValues[queryItem.key] == queryItem.value
                    }
            }
            pending.removeAll { candidate in
                matches.contains { $0.stub === candidate.stub }
            }
            return matches
        }
        for match in matches {
            afterRemoval?(match.stub)
            match.stub.deliverIfActive(match.response)
        }
    }

    static func makeSession(scope: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        config.httpAdditionalHeaders = [scopeHeader: scope]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let scope = request.value(forHTTPHeaderField: Self.scopeHeader) ?? Self.unroutedScope
        let queryItems =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryValues = Dictionary(
            queryItems.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        let match = Self.lock.withLock { () -> Response in
            let match =
                Self.queryResponses.last {
                    $0.scope == scope && url.path.hasSuffix($0.pathSuffix)
                        && $0.queryItems.allSatisfy { queryValues[$0.key] == $0.value }
                }?.response
                ?? Self.responses[scope]?.first { url.path.hasSuffix($0.key) }?.value
                ?? Response(
                    status: 404, body: Data("{}".utf8), headers: [:], suspended: false)
            if match.suspended, deliveryState.canRegisterPendingResponse() {
                Self.pending.append(
                    PendingResponse(
                        stub: self, scope: scope, path: url.path,
                        queryValues: queryValues, response: match))
            }
            Self.scopedRequests.append((scope, request))
            return match
        }
        if match.suspended {
            return
        }
        deliverIfActive(match)
    }

    private func deliverIfActive(_ match: Response) {
        guard deliveryState.claimDelivery() else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: match.status,
            httpVersion: "HTTP/1.1", headerFields: match.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryState.stop()
        Self.lock.withLock {
            Self.pending.removeAll { $0.stub === self }
        }
    }
}
