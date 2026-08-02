// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleBlockSanitizerTests {
    @Test func keepsHeadingsParagraphsListsQuotesCodeImagesAndCaptions() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "structural"))
        let repeatedSnapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "structural"))

        #expect(snapshot.blocks.map(\.kind) == [
            .heading, .paragraph, .listItem, .listItem, .quote, .code, .image, .separator,
        ])
        #expect(snapshot.blocks[1].sourceURL?.absoluteString == "https://example.test/notes")
        #expect(snapshot.blocks[5].text == "let answer = 42")
        #expect(snapshot.blocks[5].codeLanguage == "swift")
        #expect(snapshot.blocks[6].imageCandidateURL?.absoluteString == "https://example.test/images/cover.png")
        #expect(snapshot.blocks[6].caption == "A useful caption.")
        #expect(snapshot.contentState == .ready)
        #expect(snapshot.snapshotSHA256 == repeatedSnapshot.snapshotSHA256)
        #expect(snapshot.snapshotSHA256.count == 64)
        #expect(snapshot.blocks.map(\.id) == [
            "article-11111111-1111-1111-1111-111111111111-b0",
            "article-11111111-1111-1111-1111-111111111111-b1",
            "article-11111111-1111-1111-1111-111111111111-b2",
            "article-11111111-1111-1111-1111-111111111111-b3",
            "article-11111111-1111-1111-1111-111111111111-b4",
            "article-11111111-1111-1111-1111-111111111111-b5",
            "article-11111111-1111-1111-1111-111111111111-b6",
            "article-11111111-1111-1111-1111-111111111111-b7",
        ])
    }

    @Test func stripsScriptsFormsFramesEventHandlersAndHiddenActiveContent() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "malicious"))
        let encoded = String(decoding: try JSONEncoder.articleWorkshop.encode(snapshot), as: UTF8.self).lowercased()

        #expect(snapshot.blocks.compactMap(\.text).joined(separator: " ").contains("Safe paragraph bad link. local link unknown link Visible article text. Entity probe"))
        #expect(snapshot.blocks.allSatisfy { $0.imageCandidateURL == nil })
        #expect(!encoded.contains("<script"))
        #expect(!encoded.contains("<form"))
        #expect(!encoded.contains("<iframe"))
        #expect(!encoded.contains("onclick"))
        #expect(!encoded.contains("javascript:"))
        #expect(!encoded.contains("file:"))
        #expect(!encoded.contains("data:image"))
        #expect(!encoded.contains("window.pwned"))
        #expect(!encoded.contains("/etc/passwd"))
        #expect(!encoded.contains("xxe"))
        #expect(!encoded.contains("root:"))
    }

    @Test func rejectsJavaScriptFileAndUnknownSchemes() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "malicious"))

        #expect(snapshot.blocks.compactMap(\.sourceURL).isEmpty)
        #expect(snapshot.warnings.contains(.rejectedURLScheme))
    }

    @Test func resolvesRelativeHTTPLinksAgainstSourceURL() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "structural"))

        #expect(snapshot.blocks[1].sourceURL == URL(string: "https://example.test/notes"))
    }

    @Test func boundsBlockAndImageCandidateCounts() throws {
        let images = String(repeating: "<img src=\"/image.png\"/>", count: ArticleWorkshopLimits.maxImages + 1)
        let imagesEnvelope = fixtureEnvelope(contentXHTML: "<article><p>Intro.</p>\(images)</article>")
        let paragraphs = String(repeating: "<p>Bounded text.</p>", count: ArticleWorkshopLimits.maxBlocks + 1)
        let blocksEnvelope = fixtureEnvelope(contentXHTML: "<article>\(paragraphs)</article>")

        let imageSnapshot = try ArticleBlockSanitizer().sanitize(envelope: imagesEnvelope)
        let blockSnapshot = try ArticleBlockSanitizer().sanitize(envelope: blocksEnvelope)

        #expect(imageSnapshot.blocks.filter { $0.kind == .image }.count == ArticleWorkshopLimits.maxImages)
        #expect(imageSnapshot.warnings.contains(.imageCandidateLimitReached))
        #expect(imageSnapshot.contentState == .reviewSuggested)
        #expect(blockSnapshot.blocks.count == ArticleWorkshopLimits.maxBlocks)
        #expect(blockSnapshot.warnings.contains(.blockLimitReached))
        #expect(blockSnapshot.contentState == .reviewSuggested)
    }

    @Test func skipsQualifiedAndUnlistedActiveSubtreesInsideAllowedParagraphs() throws {
        let envelope = fixtureEnvelope(contentXHTML: """
            <article xmlns="http://www.w3.org/1999/xhtml" xmlns:evil="urn:evil">
              <p>Before <evil:script>namespace payload</evil:script><audio>audio payload</audio><video>video payload</video><canvas>canvas payload</canvas> after.</p>
            </article>
            """)

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)
        let encoded = String(decoding: try JSONEncoder.articleWorkshop.encode(snapshot), as: UTF8.self)

        #expect(snapshot.blocks.compactMap(\.text) == ["Before after."])
        #expect(!encoded.contains("payload"))
    }

    @Test func rejectedImagesDoNotConsumeCandidatesOrBlockLaterSafeContent() throws {
        let rejectedImages = String(repeating: "<img src=\"file:///etc/passwd\"/>", count: ArticleWorkshopLimits.maxImages + 1)
        let envelope = fixtureEnvelope(contentXHTML: """
            <article>
              <p>Before rejected images.</p>\(rejectedImages)
              <p>After rejected images.</p><img src="/safe.png"/>
            </article>
            """)

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)

        #expect(snapshot.blocks.compactMap(\.text) == ["Before rejected images.", "After rejected images."])
        #expect(snapshot.blocks.filter { $0.kind == .image }.count == 1)
        #expect(snapshot.blocks.last?.imageCandidateURL == URL(string: "https://example.test/safe.png"))
        #expect(!snapshot.warnings.contains(.imageCandidateLimitReached))
    }

    @Test func boundsDOMElementCountDuringStreamingParse() throws {
        let spans = String(repeating: "<span>ignored wrapper</span>", count: ArticleWorkshopLimits.maxDOMElements + 1)
        let envelope = fixtureEnvelope(contentXHTML: "<article><p>Intro.</p>\(spans)</article>")

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)

        #expect(snapshot.blocks.compactMap(\.text) == ["Intro."])
        #expect(snapshot.warnings.contains(.elementLimitReached))
        #expect(snapshot.contentState == .reviewSuggested)
    }

    @Test func captionOnlyContentIsReadableAndReady() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "caption-only"))

        #expect(snapshot.blocks.map(\.kind) == [.paragraph])
        #expect(snapshot.blocks.map(\.text) == ["Caption-only readable content."])
        #expect(snapshot.contentState == .ready)
    }

    @Test func malformedXHTMLBecomesReviewSuggestedWithoutExecutingAnything() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "malformed"))

        #expect(snapshot.contentState == .reviewSuggested)
        #expect(snapshot.warnings.contains(.parserFailure))
        #expect(snapshot.blocks.compactMap(\.text).joined() == "Unclosed paragraph")
    }

    @Test func acceptsReadabilityNonBreakingSpaceEntitiesWithoutAnHTMLDTD() throws {
        let envelope = fixtureEnvelope(
            contentXHTML: "<article><p>One&nbsp;two &amp; three.</p></article>")

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)

        #expect(snapshot.contentState == .ready)
        #expect(snapshot.warnings.contains(.parserFailure) == false)
        #expect(snapshot.blocks.count == 1)
        #expect(snapshot.blocks[0].text?.contains("One") == true)
        #expect(snapshot.blocks[0].text?.contains("two & three.") == true)
    }

    @Test func acceptsReadabilityHTMLVoidElementsWithoutXMLClosingSlashes() throws {
        let envelope = fixtureEnvelope(contentXHTML: """
            <article>
              <p>Before image.<br>After break.</p>
              <figure><img src="/cover.png" alt="a > b"><figcaption>Cover.</figcaption></figure>
              <hr>
            </article>
            """)

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)

        #expect(snapshot.contentState == .ready)
        #expect(snapshot.warnings.contains(.parserFailure) == false)
        #expect(snapshot.blocks.map(\.kind) == [.paragraph, .image, .separator])
        #expect(snapshot.blocks[0].text == "Before image. After break.")
        #expect(snapshot.blocks[1].imageCandidateURL == URL(string: "https://example.test/cover.png"))
        #expect(snapshot.blocks[1].caption == "Cover.")
    }

    @Test func keepsParagraphsInsideGoogleArticleParagraphContainers() throws {
        let envelope = fixtureEnvelope(contentXHTML: """
            <article><uni-article-paragraph><div><p>Satellite article text.</p></div></uni-article-paragraph></article>
            """)

        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: envelope)

        #expect(snapshot.contentState == .ready)
        #expect(snapshot.blocks.map(\.text) == ["Satellite article text."])
    }

    @Test func blockIDsRemainStableWhenCleanupExcludesNeighbors() throws {
        let snapshot = try ArticleBlockSanitizer().sanitize(envelope: fixtureEnvelope(named: "structural"))
        let recipe = ArticleEditRecipe(
            excludedBlockIDs: [snapshot.blocks[0].id, snapshot.blocks[2].id],
            trimBeforeBlockID: nil,
            trimAfterBlockID: nil,
            metadataOverrides: .init())

        let cleaned = try ArticleRevisionService().apply(snapshot: snapshot, recipe: recipe)

        #expect(cleaned.blocks.map(\.id) == [snapshot.blocks[1].id] + snapshot.blocks[3...].map(\.id))
        #expect(cleaned.blocks.map(\.stableOrdinal) == [1, 3, 4, 5, 6, 7])
    }

    private func fixtureEnvelope(named name: String) throws -> ArticleCaptureEnvelope {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ArticleWorkshop/\(name).xhtml")
        return fixtureEnvelope(contentXHTML: try String(contentsOf: fixture, encoding: .utf8))
    }

    private func fixtureEnvelope(contentXHTML: String) -> ArticleCaptureEnvelope {
        ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            method: .safariRenderedPage,
            sourceApplication: nil,
            payload: ReadabilityCapturePayload(
                sourceURL: "https://example.test/article",
                canonicalURL: "https://example.test/article",
                title: "A Small Article",
                byline: "A. Writer",
                siteName: "Example",
                language: "en",
                publishedTime: "2026-07-28",
                excerpt: "Fixture excerpt.",
                contentXHTML: contentXHTML,
                textContent: "Fixture fallback.",
                imageURLs: []))
    }
}
