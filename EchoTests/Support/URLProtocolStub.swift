// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A `URLProtocol` that returns canned responses keyed by URL path suffix.
/// Register a session via `URLProtocolStub.makeSession()` and stub responses
/// with `URLProtocolStub.stub(pathSuffix:status:json:)`.
final class URLProtocolStub: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func reset() {
        responses = [:]
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
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let match =
            Self.responses.first { path.hasSuffix($0.key) }?.value
            ?? Response(status: 404, body: Data("{}".utf8), headers: [:])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: match.status,
            httpVersion: "HTTP/1.1", headerFields: match.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
