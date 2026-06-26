// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A `URLProtocol` that returns canned responses keyed by URL path suffix.
/// Register a session via `URLProtocolStub.makeSession()` and stub responses
/// with `URLProtocolStub.stub(pathSuffix:status:json:)`.
// `nonisolated`: a `URLProtocol` subclass whose overrides (`canInit`, `startLoading`,
// etc.) must match URLProtocol's nonisolated isolation. Under Swift 6 MainActor
// default isolation the class would otherwise be inferred `@MainActor`, mismatching
// every override. (URLProtocol drives these on URLSession's loading threads.)
nonisolated final class URLProtocolStub: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var queryResponses: [QueryResponse] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    private struct QueryResponse {
        var pathSuffix: String
        var queryItems: [String: String]
        var response: Response
    }

    static func reset() {
        responses = [:]
        queryResponses = []
        requests = []
    }

    static func stub(
        pathSuffix: String, status: Int = 200, json: String, headers: [String: String] = [:]
    ) {
        responses[pathSuffix] = Response(status: status, body: Data(json.utf8), headers: headers)
    }
    static func stub(
        pathSuffix: String, status: Int = 200, data: Data, headers: [String: String] = [:]
    ) {
        responses[pathSuffix] = Response(status: status, body: data, headers: headers)
    }
    static func stub(
        pathSuffix: String, queryItems: [String: String], status: Int = 200, json: String,
        headers: [String: String] = [:]
    ) {
        queryResponses.append(
            QueryResponse(
                pathSuffix: pathSuffix,
                queryItems: queryItems,
                response: Response(status: status, body: Data(json.utf8), headers: headers)))
    }
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let queryItems =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryValues = Dictionary(
            queryItems.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        let match =
            Self.queryResponses.first {
                url.path.hasSuffix($0.pathSuffix)
                    && $0.queryItems.allSatisfy { queryValues[$0.key] == $0.value }
            }?.response
            ?? Self.responses.first { url.path.hasSuffix($0.key) }?.value
            ?? Response(status: 404, body: Data("{}".utf8), headers: [:])
        let response = HTTPURLResponse(
            url: url, statusCode: match.status,
            httpVersion: "HTTP/1.1", headerFields: match.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
