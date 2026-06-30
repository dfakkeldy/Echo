// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    /// Sequential per-call responses, consumed FIFO as `startLoading` fires. Lets a
    /// single test stub the multi-call two-pass generator (brief, then batch1, batch2, …).
    /// Takes priority over `handler`; falls back to `handler` once drained. Reset between tests.
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    /// Extra headers merged into the stubbed HTTPURLResponse. Reset between tests.
    nonisolated(unsafe) static var extraHeaders: [String: String] = [:]

    /// Clears all stub state. Call at the start of any test that uses `responses`.
    static func reset() {
        handler = nil
        responses = []
        extraHeaders = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let (status, data): (Int, Data)
        if !Self.responses.isEmpty {
            (status, data) = Self.responses.removeFirst()
        } else {
            (status, data) = Self.handler?(request) ?? (500, Data())
        }
        var headers = Self.extraHeaders
        headers["Content-Type"] = "application/json"
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
