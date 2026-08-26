// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleCaptureEnvelopeTests {
    @Test func envelopeRoundTripsWithoutBrowserSecrets() throws {
        let payload = ReadabilityCapturePayload(
            sourceURL: "https://example.test/article",
            canonicalURL: "https://example.test/article",
            title: "A Small Article",
            byline: "A. Writer",
            siteName: "Example",
            language: "en",
            publishedTime: "2026-07-28",
            excerpt: "A fixture.",
            contentXHTML: "<article><p>Body.</p></article>",
            textContent: "Body.",
            imageURLs: []
        )
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            method: .safariRenderedPage,
            sourceApplication: "com.apple.mobilesafari",
            payload: payload
        )

        let data = try JSONEncoder.articleWorkshop.encode(envelope)
        let decoded = try JSONDecoder.articleWorkshop.decode(
            ArticleCaptureEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(String(decoding: data, as: UTF8.self).contains("cookie") == false)
        #expect(String(decoding: data, as: UTF8.self).contains("authorization") == false)
    }

    @Test func limitsAreBounded() {
        #expect(ArticleWorkshopLimits.maxEnvelopeBytes == 12 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxContentXHTMLBytes == 8 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxDOMElements == 50_000)
        #expect(ArticleWorkshopLimits.maxBlocks == 20_000)
        #expect(ArticleWorkshopLimits.maxImages == 100)
        #expect(ArticleWorkshopLimits.maxSingleImageBytes == 12 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxTotalImageBytes == 50 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxRedirects == 5)
    }
}
