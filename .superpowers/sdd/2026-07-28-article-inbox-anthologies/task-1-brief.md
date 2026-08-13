### Task 1: Pin Readability and define the capture envelope

**Files:**
- Create: `ThirdParty/Readability/Readability.js`
- Create: `ThirdParty/Readability/LICENSE.md`
- Create: `ThirdParty/Readability/PIN.json`
- Create: `Scripts/verify_readability_vendor.sh`
- Create: `Shared/ArticleCapture/ArticleWorkshopLimits.swift`
- Create: `Shared/ArticleCapture/ArticleCaptureEnvelope.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleCaptureEnvelopeTests.swift`

**Interfaces:**
- Produces: `ArticleWorkshopLimits`, `ArticleCaptureEnvelope`, `ReadabilityCapturePayload`, `ArticleCaptureMethod`.
- Consumes: no prior task APIs.

- [ ] **Step 1: Add failing envelope and bounds tests**

```swift
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
```

- [ ] **Step 2: Run the tests and vendor check to verify failure**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
```

Expected: the Swift suite fails to compile because the capture types do not exist; the shell check fails because the pinned files do not exist.

- [ ] **Step 3: Add the exact capture contract and limits**

```swift
nonisolated enum ArticleWorkshopLimits {
    static let maxEnvelopeBytes = 12 * 1_024 * 1_024
    static let maxContentXHTMLBytes = 8 * 1_024 * 1_024
    static let maxDOMElements = 50_000
    static let maxBlocks = 20_000
    static let maxImages = 100
    static let maxSingleImageBytes = 12 * 1_024 * 1_024
    static let maxTotalImageBytes = 50 * 1_024 * 1_024
    static let maxRedirects = 5
    static let maxURLResponseBytes = 12 * 1_024 * 1_024
}

nonisolated enum ArticleCaptureMethod: String, Codable, Sendable {
    case safariRenderedPage
    case urlFetch
}

nonisolated struct ReadabilityCapturePayload: Codable, Equatable, Sendable {
    let sourceURL: String
    let canonicalURL: String?
    let title: String?
    let byline: String?
    let siteName: String?
    let language: String?
    let publishedTime: String?
    let excerpt: String?
    let contentXHTML: String
    let textContent: String
    let imageURLs: [String]
}

nonisolated struct ArticleCaptureEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let captureID: UUID
    let capturedAt: Date
    let method: ArticleCaptureMethod
    let sourceApplication: String?
    let payload: ReadabilityCapturePayload
}
```

Use fixed ISO-8601-with-fractional-seconds encoder/decoder factories so share extension and host app encode identically. Do not add credential-shaped fields.

- [ ] **Step 4: Vendor and verify Readability 0.6.0**

Commit the exact npm 0.6.0 `Readability.js` and Apache license. `PIN.json` must contain:

```json
{
  "package": "@mozilla/readability",
  "version": "0.6.0",
  "gitHead": "4d5dd0bbe0bfbc44e219dc86865131e79639e30b",
  "npmTarball": "https://registry.npmjs.org/@mozilla/readability/-/readability-0.6.0.tgz",
  "npmIntegrity": "sha512-juG5VWh4qAivzTAeMzvY9xs9HY5rAcr2E4I7tiSSCokRFi7XIZCAu92ZkSTsIj1OPceCifL3cpfteP3pDT9/QQ==",
  "npmSHA1": "134e3ce3ff1676716e550de0b8de957bcc59208b",
  "license": "Apache-2.0"
}
```

The verification script downloads the tarball to `mktemp -d`, checks npm integrity with `openssl dgst -sha512 -binary | openssl base64 -A`, extracts `package/Readability.js`, byte-compares it with the committed file, verifies `LICENSE.md`, and removes its temporary directory through a trap.

- [ ] **Step 5: Run focused verification**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
git diff --check
```

Expected: both tests and the pin check pass.

- [ ] **Step 6: Commit**

```bash
git add ThirdParty/Readability Scripts/verify_readability_vendor.sh Shared/ArticleCapture EchoTests/ArticleWorkshop/ArticleCaptureEnvelopeTests.swift
git commit -m "feat: pin readability capture contract"
```

---
