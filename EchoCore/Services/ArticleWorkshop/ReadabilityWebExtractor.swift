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

        var errorDescription: String? {
            switch self {
            case .vendoredSourceUnavailable: "The pinned Readability source is unavailable."
            case .ruleCompilationFailed: "The isolated article document could not be configured."
            case .navigationFailed: "The isolated article document could not be loaded."
            case .invalidPayload: "Readability did not return a valid article payload."
            }
        }
    }

    typealias SourceProvider = @MainActor @Sendable () throws -> String

    private let sourceProvider: SourceProvider
    private var navigationContinuation: CheckedContinuation<Void, Swift.Error>?
    private weak var webView: WKWebView?

    init(sourceProvider: @escaping SourceProvider = { try ReadabilityWebExtractor.vendoredReadabilitySource() }) {
        self.sourceProvider = sourceProvider
    }

    func extract(html: String, sourceURL: URL) async throws -> ReadabilityCapturePayload {
        guard ArticleNetworkURLPolicy.normalized(sourceURL) != nil else {
            throw Error.navigationFailed
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let rules = try await blockingRules()
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            self.webView = nil
        }
        try await load(html: html, into: webView, baseURL: sourceURL)
        let source = try sourceProvider()
        try await evaluateReadability(source, in: webView)
        let json = try await evaluatePayload(Self.extractionAdapter, in: webView)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReadabilityCapturePayload.self, from: data),
              payload.contentXHTML.isEmpty == false,
              payload.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { throw Error.invalidPayload }
        return payload
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeNavigation(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Swift.Error) {
        resumeNavigation(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Swift.Error) {
        resumeNavigation(with: .failure(error))
    }

    private func blockingRules() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "echo-readability-no-subresources-v1",
                encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"image\",\"style-sheet\",\"script\",\"font\",\"media\",\"raw\",\"svg-document\"]},\"action\":{\"type\":\"block\"}}]"
            ) { rules, error in
                if let rules { continuation.resume(returning: rules) }
                else { continuation.resume(throwing: error ?? Error.ruleCompilationFailed) }
            }
        }
    }

    private func load(html: String, into webView: WKWebView, baseURL: URL) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }, onCancel: { [weak self, weak webView] in
            Task { @MainActor in
                webView?.stopLoading()
                self?.resumeNavigation(with: .failure(CancellationError()))
            }
        })
    }

    private func evaluateReadability(_ source: String, in webView: WKWebView) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [weak webView] in
            Task { @MainActor in webView?.stopLoading() }
        })
    }

    private func evaluatePayload(_ source: String, in webView: WKWebView) async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value as String): continuation.resume(returning: value)
                    case .success: continuation.resume(throwing: Error.invalidPayload)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [weak webView] in
            Task { @MainActor in webView?.stopLoading() }
        })
    }

    private func resumeNavigation(with result: Result<Void, Swift.Error>) {
        let continuation = navigationContinuation
        navigationContinuation = nil
        continuation?.resume(with: result)
    }

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
