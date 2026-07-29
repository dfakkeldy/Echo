// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

#if canImport(WebKit)
@MainActor
@Suite struct ReadabilityWebExtractorPolicyTests {
    @Test func blocksEveryDocumentAndSubresourceClassWithoutAllowingFollowupNavigation() {
        let rule = ReadabilityWebExtractor.blockingRuleJSON

        for resource in ["document", "image", "style-sheet", "script", "font", "media", "raw", "svg-document"] {
            #expect(rule.contains("\"\(resource)\""))
        }
        #expect(ReadabilityWebExtractor.permitsNavigation(
            isInitialNavigation: true, isMainFrame: true, hasPendingNavigation: true))
        #expect(ReadabilityWebExtractor.permitsNavigation(
            isInitialNavigation: false, isMainFrame: true, hasPendingNavigation: true) == false)
        #expect(ReadabilityWebExtractor.permitsNavigation(
            isInitialNavigation: true, isMainFrame: false, hasPendingNavigation: true) == false)
    }

    @Test func cancellationAndLateCallbackGatesAreOnceOnly() {
        let active = UUID()

        #expect(ReadabilityWebExtractor.shouldIssueCancellation(alreadyIssued: false))
        #expect(ReadabilityWebExtractor.shouldIssueCancellation(alreadyIssued: true) == false)
        #expect(ReadabilityWebExtractor.acceptsCallback(activeToken: active, callbackToken: active))
        #expect(ReadabilityWebExtractor.acceptsCallback(activeToken: nil, callbackToken: active) == false)
        #expect(ReadabilityWebExtractor.acceptsCallback(activeToken: UUID(), callbackToken: active) == false)
    }
}
#endif

@Suite(.serialized) struct ArticleURLCaptureServiceTests {
    @Test func followsAtMostFiveHTTPRedirects() async throws {
        ArticleURLProtocol.install { request in
            let hop = Int(request.url?.lastPathComponent ?? "0") ?? 0
            let destination = URL(string: "https://example.test/redirect/\(hop + 1)")!
            return .redirect(destination)
        }
        defer { ArticleURLProtocol.reset() }

        let service = ArticleURLCaptureService(
            sessionConfiguration: articleURLProtocolConfiguration(),
            extractor: fixtureExtractor)

        do {
            _ = try await service.capture(url: URL(string: "https://example.test/redirect/0")!)
            Issue.record("Expected redirect limit failure")
        } catch let error as ArticleURLCaptureService.Error {
            #expect(error == .tooManyRedirects)
        }
        #expect(ArticleURLProtocol.requestCount == ArticleWorkshopLimits.maxRedirects + 1)
    }

    @Test func rejectsNonHTTPURLAndNonHTMLResponse() async throws {
        let service = ArticleURLCaptureService(
            sessionConfiguration: articleURLProtocolConfiguration(),
            extractor: fixtureExtractor)
        do {
            _ = try await service.capture(url: URL(string: "file:///private/article.html")!)
            Issue.record("Expected URL scheme failure")
        } catch let error as ArticleURLCaptureService.Error {
            #expect(error == .unsupportedURL)
        }

        ArticleURLProtocol.install { _ in .response(status: 200, mimeType: "image/png", data: Data([0])) }
        defer { ArticleURLProtocol.reset() }
        do {
            _ = try await service.capture(url: URL(string: "https://example.test/article")!)
            Issue.record("Expected MIME failure")
        } catch let error as ArticleURLCaptureService.Error {
            #expect(error == .unsupportedContentType)
        }
    }

    @Test func stopsReadingResponseAtTwelveMiB() async throws {
        ArticleURLProtocol.install { _ in
            .response(
                status: 200,
                mimeType: "text/html",
                data: Data(count: ArticleWorkshopLimits.maxURLResponseBytes + 1))
        }
        defer { ArticleURLProtocol.reset() }
        let service = ArticleURLCaptureService(
            sessionConfiguration: articleURLProtocolConfiguration(),
            extractor: fixtureExtractor)

        do {
            _ = try await service.capture(url: URL(string: "https://example.test/large")!)
            Issue.record("Expected bounded-response failure")
        } catch let error as ArticleURLCaptureService.Error {
            #expect(error == .responseTooLarge)
        }
        #expect(ArticleURLProtocol.cancelledRequestCount == 1)
    }

    @Test func classifiesLoginFormInsteadOfSavingItAsTheArticle() async throws {
        ArticleURLProtocol.install { _ in
            .response(
                status: 200,
                mimeType: "text/html",
                data: Data("<html><h1>Sign in</h1><form><input type='password'></form></html>".utf8))
        }
        defer { ArticleURLProtocol.reset() }
        let service = ArticleURLCaptureService(
            sessionConfiguration: articleURLProtocolConfiguration(),
            extractor: fixtureExtractor)

        do {
            _ = try await service.capture(url: URL(string: "https://example.test/article")!)
            Issue.record("Expected authentication classification")
        } catch let error as ArticleURLCaptureService.Error {
            #expect(error == .authenticationRequired(
                message: "Open this page in Safari to capture the signed-in version."))
        }
    }

    @Test func neverRefetchesDuringLaterSnapshotLoad() async throws {
        ArticleURLProtocol.install { _ in
            .response(status: 200, mimeType: "text/html", data: Data("<article><p>Stored only once.</p></article>".utf8))
        }
        defer { ArticleURLProtocol.reset() }
        let service = ArticleURLCaptureService(
            sessionConfiguration: articleURLProtocolConfiguration(),
            extractor: fixtureExtractor)
        let payload = try await service.capture(url: URL(string: "https://example.test/article")!)
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: UUID(),
            capturedAt: .now,
            method: .urlFetch,
            sourceApplication: nil,
            payload: payload)

        _ = try ArticleBlockSanitizer().sanitize(envelope: envelope)
        #expect(ArticleURLProtocol.requestCount == 1)
    }

    @Test func clearsInjectedCredentialHeadersAndKeepsReadableLoginMention() async throws {
        var configuration = articleURLProtocolConfiguration()
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer secret", "Cookie": "session=secret", "X-Private": "secret"]
        ArticleURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Private") == nil)
            return .response(
                status: 200,
                mimeType: "text/html",
                data: Data("<article><h1>How sign in works</h1><p>Long readable text.</p><p>More readable text.</p><input type='password'></article>".utf8))
        }
        defer { ArticleURLProtocol.reset() }
        let service = ArticleURLCaptureService(sessionConfiguration: configuration, extractor: fixtureExtractor)
        _ = try await service.capture(url: URL(string: "https://example.test/author/article")!)
        #expect(ArticleURLProtocol.requestCount == 1)
    }

    private var fixtureExtractor: ArticleURLCaptureService.Extractor {
        { html, url in
            ReadabilityCapturePayload(
                sourceURL: url.absoluteString,
                canonicalURL: url.absoluteString,
                title: "Fixture",
                byline: nil,
                siteName: nil,
                language: "en",
                publishedTime: nil,
                excerpt: nil,
                contentXHTML: html,
                textContent: "Stored only once.",
                imageURLs: [])
        }
    }
}

func articleURLProtocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArticleURLProtocol.self]
    return configuration
}

nonisolated final class ArticleURLProtocol: URLProtocol {
    enum Reply {
        case response(status: Int, mimeType: String, data: Data)
        case redirect(URL)
    }

    nonisolated(unsafe) private static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var cancelled = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static var cancelledRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = 0
        cancelled = 0
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = 0
        cancelled = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply?
        Self.lock.lock()
        Self.requests += 1
        reply = Self.handler?(request)
        Self.lock.unlock()
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch reply {
        case .redirect(let destination):
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        case .response(let status, let mimeType, let data):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mimeType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cancelled += 1
    }
}
