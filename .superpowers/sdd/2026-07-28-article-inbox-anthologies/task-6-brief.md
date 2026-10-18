### Task 6: Add URL-only fallback and safe image localization

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/ReadabilityWebExtractor.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleURLCaptureService.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleImageDownloader.swift`
- Modify: `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleURLCaptureServiceTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleImageDownloaderTests.swift`

**Interfaces:**
- Consumes: `ReadabilityCapturePayload`, `ArticleSnapshot`, `ArticleWorkshopFileStore`.
- Produces: `ArticleURLCaptureService.capture(url:)`, localized image paths and warnings.

- [ ] **Step 1: Add bounded network tests with an injected `URLProtocol`**

Cover:

```swift
@Test func followsAtMostFiveHTTPRedirects() async throws
@Test func rejectsNonHTTPURLAndNonHTMLResponse() async throws
@Test func stopsReadingResponseAtTwelveMiB() async throws
@Test func classifiesLoginFormInsteadOfSavingItAsTheArticle() async throws
@Test func neverRefetchesDuringLaterSnapshotLoad() async throws
@Test func acceptsDecodedJPEGAndPNGOnlyWithinImageBudgets() async throws
@Test func imageFailureLeavesReadableTextAndAddsWarning() async throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
make test-only FILTER=EchoTests/ArticleImageDownloaderTests
```

Expected: missing services.

- [ ] **Step 3: Implement bounded URL loading**

`ArticleURLCaptureService` accepts only `http` and `https`, uses an ephemeral injected `URLSession`, rejects non-HTML MIME types, enforces response/redirect limits in its delegate, and never stores request/response headers. A response dominated by password inputs, “sign in” headings, or a redirect to a known login path returns:

```swift
case authenticationRequired(
    message: "Open this page in Safari to capture the signed-in version."
)
```

- [ ] **Step 4: Extract with a network-silent WebKit document**

`ReadabilityWebExtractor` uses a nonpersistent `WKWebView`, disables page-authored JavaScript, installs a content rule that blocks all subresource loads, loads the already-fetched HTML with the source URL as base, and evaluates the pinned Readability source in the client content world. It returns the same `ReadabilityCapturePayload` used by Safari. Cancellation tears down the navigation and continuation exactly once.

`ArticleImageDownloader` separately downloads normalized `http`/`https` candidates, verifies MIME and decoded image dimensions with ImageIO, writes accepted assets atomically under the capture directory, and stops at `maxImages`, `maxSingleImageBytes`, or `maxTotalImageBytes`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
make test-only FILTER=EchoTests/ArticleImageDownloaderTests
```

Expected: pass without network access beyond the injected protocol.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: add local URL article capture"
```

---
