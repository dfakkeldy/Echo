// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@MainActor
struct ArticleURLCaptureService {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case unsupportedURL
        case tooManyRedirects
        case responseTooLarge
        case invalidHTTPResponse
        case unsupportedContentType
        case invalidTextEncoding
        case authenticationRequired(message: String)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedURL: "Only HTTP(S) article URLs can be captured."
            case .tooManyRedirects: "The article redirected too many times."
            case .responseTooLarge: "The article response exceeds the supported size."
            case .invalidHTTPResponse: "The article server returned an unsuccessful response."
            case .unsupportedContentType: "The article server did not return HTML."
            case .invalidTextEncoding: "The article response could not be decoded as text."
            case .authenticationRequired(let message): message
            case .extractionFailed: "The article could not be extracted."
            }
        }
    }

    typealias Extractor = @MainActor @Sendable (_ html: String, _ sourceURL: URL) async throws -> ReadabilityCapturePayload

    private let sessionConfiguration: URLSessionConfiguration
    private let extractor: Extractor

    init(
        sessionConfiguration: URLSessionConfiguration = Self.ephemeralConfiguration(),
        extractor: Extractor? = nil
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.extractor = extractor ?? { html, sourceURL in
            try await ReadabilityWebExtractor().extract(html: html, sourceURL: sourceURL)
        }
    }

    func capture(url: URL) async throws -> ReadabilityCapturePayload {
        guard let normalizedURL = ArticleNetworkURLPolicy.normalized(url) else {
            throw Error.unsupportedURL
        }
        let loader = ArticleBoundedURLLoader(
            configuration: sessionConfiguration,
            acceptedMIMETypes: ["text/html", "application/xhtml+xml"],
            maximumBytes: ArticleWorkshopLimits.maxURLResponseBytes)
        let response: ArticleBoundedURLLoader.Response
        do {
            response = try await loader.load(url: normalizedURL)
        } catch let error as ArticleBoundedURLLoader.Error {
            throw Self.error(for: error)
        }
        guard let html = String(data: response.data, encoding: .utf8) else {
            throw Error.invalidTextEncoding
        }
        if Self.requiresAuthentication(html: html, finalURL: response.url) {
            throw Error.authenticationRequired(
                message: "Open this page in Safari to capture the signed-in version.")
        }
        do {
            return try await extractor(html, response.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.extractionFailed
        }
    }

    nonisolated static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private static func error(for error: ArticleBoundedURLLoader.Error) -> Error {
        switch error {
        case .unsupportedURL: .unsupportedURL
        case .tooManyRedirects: .tooManyRedirects
        case .responseTooLarge: .responseTooLarge
        case .invalidHTTPResponse: .invalidHTTPResponse
        case .unsupportedContentType: .unsupportedContentType
        case .cancelled: .extractionFailed
        case .transport: .invalidHTTPResponse
        }
    }

    private static func requiresAuthentication(html: String, finalURL: URL) -> Bool {
        let pathComponents = finalURL.path.lowercased().split(separator: "/")
        if pathComponents.contains(where: { authenticationPathComponents.contains(String($0)) }) {
            return true
        }
        let lowercased = html.lowercased()
        let passwordInput = #"<input\b[^>]*\btype\s*=\s*[\"']?password\b"#
        let forms = lowercased.matches(of: try! Regex(#"(?s)<form\b[^>]*>.*?</form>"#))
        if forms.contains(where: { form in
            let markup = String(lowercased[form.range])
            return markup.contains("password")
                && markup.contains(regex: passwordInput)
                && (formActionContainsAuthenticationPath(markup)
                    || controlAttributesContainLoginSignal(markup)
                    || visibleElementsContainLoginSignal(markup))
        }) { return true }
        // Some sites place the heading immediately outside an otherwise standard form.
        return lowercased.contains(regex: passwordInput)
            && headingElementsContainLoginSignal(lowercased)
    }

    private static let authenticationPathComponents: Set<String> = [
        "login", "signin", "sign-in", "auth", "authenticate", "authentication"
    ]

    private static func formActionContainsAuthenticationPath(_ markup: String) -> Bool {
        guard let openingForm = markup.firstMatch(of: try! Regex(#"<form\b[^>]*>"#)) else {
            return false
        }
        return attributeValues(named: "action", in: String(markup[openingForm.range])).contains { action in
            let path = URLComponents(string: action)?.path ?? action
            return path.lowercased().split(separator: "/").contains {
                authenticationPathComponents.contains(String($0))
            }
        }
    }

    private static func controlAttributesContainLoginSignal(_ markup: String) -> Bool {
        let controls = markup.matches(of: try! Regex(#"<(?:input|button)\b[^>]*>"#))
        return controls.contains { control in
            let tag = String(markup[control.range])
            return ["value", "aria-label", "title", "name", "id"].contains { attribute in
                attributeValues(named: attribute, in: tag).contains(where: containsLoginSignal)
            }
        }
    }

    private static func visibleElementsContainLoginSignal(_ markup: String) -> Bool {
        elementsContainLoginSignal(markup, matching: #"(?is)<(?:button|label|h[1-6])\b[^>]*>.*?</(?:button|label|h[1-6])>"#)
    }

    private static func headingElementsContainLoginSignal(_ markup: String) -> Bool {
        markup.matches(of: try! Regex(#"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]>"#)).contains { element in
            normalizedVisibleText(String(markup[element.range])).contains(regex: #"^(?:sign\s*in|log\s*in|login)\b"#)
        }
    }

    private static func elementsContainLoginSignal(_ markup: String, matching pattern: String) -> Bool {
        markup.matches(of: try! Regex(pattern)).contains { element in
            containsLoginSignal(normalizedVisibleText(String(markup[element.range])))
        }
    }

    private static func normalizedVisibleText(_ markup: String) -> String {
        markup
            .replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsLoginSignal(_ value: String) -> Bool {
        value.contains(regex: #"\b(?:sign\s*in|log\s*in|login|auth|authenticate|authentication)\b"#)
    }

    private static func attributeValues(named name: String, in markup: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_-])"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let wholeRange = NSRange(markup.startIndex..<markup.endIndex, in: markup)
        var values: [String] = []
        for match in expression.matches(in: markup, range: wholeRange) {
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let stringRange = Range(range, in: markup)
                else { continue }
                values.append(String(markup[stringRange]))
                break
            }
        }
        return values
    }
}

private extension String {
    func contains(regex pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

nonisolated enum ArticleNetworkURLPolicy {
    static func normalized(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { return nil }
        components.scheme = scheme
        components.fragment = nil
        guard let normalized = components.url, normalized.isFileURL == false else { return nil }
        return normalized
    }
}

// All mutable delegate state is accessed only while `lock` is held. URLSession
// callbacks may arrive on arbitrary queues, so this type is deliberately
// nonisolated and its @unchecked Sendable conformance is limited to that invariant.
nonisolated final class ArticleBoundedURLLoader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Error: Swift.Error {
        case unsupportedURL
        case tooManyRedirects
        case responseTooLarge
        case invalidHTTPResponse
        case unsupportedContentType
        case cancelled
        case transport(Swift.Error)
    }

    struct Response: Sendable {
        let data: Data
        let url: URL
        let mimeType: String
    }

    private let configuration: URLSessionConfiguration
    private let acceptedMIMETypes: Set<String>
    private let maximumBytes: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Response, Swift.Error>?
    private var data = Data()
    private var finalURL: URL?
    private var finalMIMEType: String?
    private var redirects = 0
    private var completed = false

    init(configuration: URLSessionConfiguration, acceptedMIMETypes: Set<String>, maximumBytes: Int) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.httpCookieStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCredentialStorage = nil
        self.configuration.urlCache = nil
        self.configuration.httpAdditionalHeaders = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.acceptedMIMETypes = acceptedMIMETypes
        self.maximumBytes = maximumBytes
    }

    func load(url: URL) async throws -> Response {
        guard ArticleNetworkURLPolicy.normalized(url) != nil else { throw Error.unsupportedURL }
        return try await withTaskCancellationHandler(operation: {
            if Task.isCancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard completed == false else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: URLRequest(url: url))
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.finish(throwing: CancellationError())
        })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectedURL = request.url, let normalizedRedirectURL = ArticleNetworkURLPolicy.normalized(redirectedURL) else {
            finish(throwing: Error.unsupportedURL)
            completionHandler(nil)
            return
        }
        lock.lock()
        let mayFollow = completed == false && redirects < ArticleWorkshopLimits.maxRedirects
        if mayFollow { redirects += 1 }
        lock.unlock()
        guard mayFollow else {
            finish(throwing: Error.tooManyRedirects)
            completionHandler(nil)
            return
        }
        var normalizedRequest = URLRequest(url: normalizedRedirectURL)
        normalizedRequest.httpMethod = request.httpMethod
        completionHandler(normalizedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode)
        else {
            finish(throwing: Error.invalidHTTPResponse)
            completionHandler(.cancel)
            return
        }
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard acceptedMIMETypes.contains(mimeType) else {
            finish(throwing: Error.unsupportedContentType)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        finalURL = response.url
        finalMIMEType = mimeType
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceedsLimit = data.count > maximumBytes - self.data.count
        if !exceedsLimit && !completed { self.data.append(data) }
        lock.unlock()
        if exceedsLimit { finish(throwing: Error.responseTooLarge) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Swift.Error)?) {
        if let error {
            finish(throwing: error is CancellationError ? CancellationError() : Error.transport(error))
            return
        }
        lock.lock()
        let response = finalURL.flatMap { url in finalMIMEType.map { Response(data: data, url: url, mimeType: $0) } }
        lock.unlock()
        guard let response else {
            finish(throwing: Error.invalidHTTPResponse)
            return
        }
        finish(returning: response)
    }

    private func finish(returning response: Response) {
        finish(with: .success(response))
    }

    private func finish(throwing error: Swift.Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Response, Swift.Error>) {
        lock.lock()
        guard completed == false else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
