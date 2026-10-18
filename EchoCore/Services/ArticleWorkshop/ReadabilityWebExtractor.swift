// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if canImport(WebKit)
import WebKit

@MainActor
final class ReadabilityWebExtractor: NSObject, WKNavigationDelegate {
    enum Error: Swift.Error, LocalizedError {
        case vendoredSourceUnavailable
        case ruleCompilationFailed
        case navigationFailed
        case invalidPayload
        case extractionInProgress

        var errorDescription: String? {
            switch self {
            case .vendoredSourceUnavailable: "The pinned Readability source is unavailable."
            case .ruleCompilationFailed: "The isolated article document could not be configured."
            case .navigationFailed: "The isolated article document could not be loaded."
            case .invalidPayload: "Readability did not return a valid article payload."
            case .extractionInProgress: "Another article extraction is already in progress."
            }
        }
    }

    typealias SourceProvider = @MainActor @Sendable () throws -> String
    typealias RuleCompiler = @MainActor @Sendable (_ rules: String, _ completion: @escaping @MainActor (Result<WKContentRuleList, Swift.Error>) -> Void) -> Void
    typealias CancellationScheduler = @MainActor @Sendable (_ extractionID: UUID, _ operation: @escaping @MainActor () -> Void) -> Void

    private let sourceProvider: SourceProvider
    private let ruleCompiler: RuleCompiler
    private let cancellationScheduler: CancellationScheduler
    private var navigationContinuation: CheckedContinuation<Void, Swift.Error>?
    private var rulesContinuation: CheckedContinuation<WKContentRuleList, Swift.Error>?
    private var parserContinuation: CheckedContinuation<Void, Swift.Error>?
    private var payloadContinuation: CheckedContinuation<String, Swift.Error>?
    private var parserToken: UUID?
    private var payloadToken: UUID?
    private var rulesToken: UUID?
    private var navigationToken: UUID?
    private weak var webView: WKWebView?
    private var allowedInitialNavigation = false
    private var cancellationIssued = false
    private var activeExtractionID: UUID?

    init(
        sourceProvider: @escaping SourceProvider = { try ReadabilityWebExtractor.vendoredReadabilitySource() },
        ruleCompiler: @escaping RuleCompiler = { rules, completion in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "echo-readability-no-subresources-v1", encodedContentRuleList: rules
            ) { list, error in completion(list.map(Result.success) ?? .failure(error ?? Error.ruleCompilationFailed)) }
        },
        cancellationScheduler: @escaping CancellationScheduler = { _, operation in Task { @MainActor in operation() } }
    ) {
        self.sourceProvider = sourceProvider
        self.ruleCompiler = ruleCompiler
        self.cancellationScheduler = cancellationScheduler
    }

    func extract(html: String, sourceURL: URL) async throws -> ReadabilityCapturePayload {
        guard ArticleNetworkURLPolicy.normalized(sourceURL) != nil else {
            throw Error.navigationFailed
        }
        guard Self.canBeginExtraction(activeExtractionID: activeExtractionID) else { throw Error.extractionInProgress }
        let extractionID = UUID()
        activeExtractionID = extractionID
        cancellationIssued = false
        defer {
            if activeExtractionID == extractionID { activeExtractionID = nil }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let rules = try await blockingRules(token: extractionID)
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        self.allowedInitialNavigation = false
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            self.webView = nil
        }
        try await load(html: html, into: webView, baseURL: sourceURL, token: extractionID)
        let source = try sourceProvider()
        try await evaluateReadability(source, in: webView, token: extractionID)
        let json = try await evaluatePayload(Self.extractionAdapter, in: webView, token: extractionID)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReadabilityCapturePayload.self, from: data),
              payload.contentXHTML.isEmpty == false,
              payload.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { throw Error.invalidPayload }
        return payload
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeNavigation(webView: webView, with: .success(()))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard Self.permitsNavigation(
            isInitialNavigation: allowedInitialNavigation == false,
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            hasPendingNavigation: navigationContinuation != nil
        )
        else {
            decisionHandler(.cancel)
            return
        }
        allowedInitialNavigation = true
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Swift.Error) {
        resumeNavigation(webView: webView, with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Swift.Error) {
        resumeNavigation(webView: webView, with: .failure(error))
    }

    private func blockingRules(token: UUID) async throws -> WKContentRuleList {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
            rulesToken = token
            rulesContinuation = continuation
            ruleCompiler(Self.blockingRuleJSON) { [weak self] result in
                self?.resumeRules(token: token, result: result)
            }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.scheduleCancellation(token) } })
    }

    private func load(html: String, into webView: WKWebView, baseURL: URL, token: UUID) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                navigationToken = token
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.scheduleCancellation(token)
            }
        })
    }

    private func evaluateReadability(_ source: String, in webView: WKWebView, token: UUID) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                parserToken = token
                parserContinuation = continuation
                webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
                    self.resumeParser(token: token, with: result.map { _ in () })
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.scheduleCancellation(token) }
        })
    }

    private func evaluatePayload(_ source: String, in webView: WKWebView, token: UUID) async throws -> String {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                payloadToken = token
                payloadContinuation = continuation
                webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
                    let payload = result.flatMap { value -> Result<String, Swift.Error> in
                        guard let value = value as? String else { return .failure(Error.invalidPayload) }
                        return .success(value)
                    }
                    self.resumePayload(token: token, with: payload)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.scheduleCancellation(token) }
        })
    }

    private func resumeNavigation(webView: WKWebView? = nil, with result: Result<Void, Swift.Error>) {
        guard Self.acceptsNavigationCallback(
            activeExtractionID: activeExtractionID,
            navigationToken: navigationToken,
            isActiveWebView: webView.map { self.webView === $0 } ?? true
        ) else { return }
        navigationToken = nil
        let continuation = navigationContinuation
        navigationContinuation = nil
        continuation?.resume(with: result)
    }

    private func resumeRules(token: UUID, result: Result<WKContentRuleList, Swift.Error>) {
        guard Self.acceptsRuleCallback(activeExtractionID: activeExtractionID, ruleToken: rulesToken, callbackToken: token) else { return }
        rulesToken = nil
        let continuation = rulesContinuation
        rulesContinuation = nil
        continuation?.resume(with: result)
    }

    private func resumeParser(token: UUID, with result: Result<Void, Swift.Error>) {
        guard Self.acceptsCallback(activeToken: parserToken, callbackToken: token) else { return }
        parserToken = nil
        let continuation = parserContinuation
        parserContinuation = nil
        continuation?.resume(with: result)
    }

    private func resumePayload(token: UUID, with result: Result<String, Swift.Error>) {
        guard Self.acceptsCallback(activeToken: payloadToken, callbackToken: token) else { return }
        payloadToken = nil
        let continuation = payloadContinuation
        payloadContinuation = nil
        continuation?.resume(with: result)
    }

    private func cancelActiveWork(extractionID: UUID) {
        guard activeExtractionID == extractionID else { return }
        guard Self.shouldIssueCancellation(alreadyIssued: cancellationIssued) else { return }
        cancellationIssued = true
        webView?.stopLoading()
        resumeNavigation(with: .failure(CancellationError()))
        if let token = rulesToken { resumeRules(token: token, result: .failure(CancellationError())) }
        if let token = parserToken {
            resumeParser(token: token, with: .failure(CancellationError()))
        }
        if let token = payloadToken {
            resumePayload(token: token, with: .failure(CancellationError()))
        }
        activeExtractionID = nil
    }

    private func scheduleCancellation(_ extractionID: UUID) {
        cancellationScheduler(extractionID) { [weak self] in self?.cancelActiveWork(extractionID: extractionID) }
    }

    static func permitsNavigation(
        isInitialNavigation: Bool,
        isMainFrame: Bool,
        hasPendingNavigation: Bool
    ) -> Bool {
        isInitialNavigation && isMainFrame && hasPendingNavigation
    }

    // These pure gates keep cancellation and late WebKit callbacks deterministic in tests.
    static func shouldIssueCancellation(alreadyIssued: Bool) -> Bool { alreadyIssued == false }

    static func acceptsCallback(activeToken: UUID?, callbackToken: UUID) -> Bool {
        activeToken == callbackToken
    }

    static func canBeginExtraction(activeExtractionID: UUID?) -> Bool { activeExtractionID == nil }

    static func acceptsRuleCallback(activeExtractionID: UUID?, ruleToken: UUID?, callbackToken: UUID) -> Bool {
        activeExtractionID == callbackToken && ruleToken == callbackToken
    }

    static func acceptsNavigationCallback(
        activeExtractionID: UUID?,
        navigationToken: UUID?,
        isActiveWebView: Bool
    ) -> Bool {
        isActiveWebView && activeExtractionID != nil && activeExtractionID == navigationToken
    }

    static let blockingRuleJSON = "[{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"document\",\"image\",\"style-sheet\",\"script\",\"font\",\"media\",\"raw\",\"svg-document\"]},\"action\":{\"type\":\"block\"}}]"

    private static func vendoredReadabilitySource() throws -> String {
        // The product bundle contains the pinned source as a resource; this code never
        // downloads or substitutes a parser. Task 5 owns target/resource wiring.
        let bundles = [Bundle.main, Bundle(for: ReadabilityWebExtractor.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "Readability", withExtension: "js"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
        throw Error.vendoredSourceUnavailable
    }

    private static let extractionAdapter = #"""
    (function() {
      var clone = document.cloneNode(true);
      var article = new Readability(clone, { maxElemsToParse: 50000, keepClasses: false }).parse();
      if (!article) { throw new Error("Readability returned no article"); }
      var content = article.content || "";
      var parsed = new DOMParser().parseFromString(content, "text/html");
      return JSON.stringify({
        sourceURL: document.location.href,
        canonicalURL: (document.querySelector("link[rel='canonical']") || {}).href || null,
        title: article.title || null,
        byline: article.byline || null,
        siteName: article.siteName || null,
        language: article.lang || document.documentElement.lang || null,
        publishedTime: article.publishedTime || null,
        excerpt: article.excerpt || null,
        contentXHTML: content,
        textContent: article.textContent || "",
        imageURLs: Array.from(parsed.images).map(function(image) {
          return image.currentSrc || image.src;
        }).filter(Boolean)
      });
    })()
    """#
}
#else
@MainActor
final class ReadabilityWebExtractor {
    enum Error: Swift.Error { case unavailable }

    init() {}

    func extract(html: String, sourceURL: URL) async throws -> ReadabilityCapturePayload {
        throw Error.unavailable
    }
}
#endif
