### Task 5: Add the multiplatform Safari share extension

**Files:**
- Create: `Echo Share Extension/ArticleCapturePreprocessor.js`
- Create: `Echo Share Extension/Info.plist`
- Create: `Echo Share Extension/EchoShareExtension.entitlements`
- Create: `Echo Share Extension/ShareViewController.swift`
- Modify: `Echo.xcodeproj/project.pbxproj`
- Test: `EchoTests/ArticleWorkshop/ArticleShareCaptureHandlerTests.swift`

**Interfaces:**
- Consumes: `ArticleCaptureEnvelope`, `ArticleCaptureStagingWriter`, Readability 0.6.0.
- Produces: a complete App Group staging package and concise extension outcome.

- [ ] **Step 1: Add native-handler tests before target wiring**

Factor decoding/writing into:

```swift
nonisolated struct ArticleShareCaptureHandler {
    let stagingWriter: ArticleCaptureStagingWriter
    func handle(
        preprocessingResults: [String: Any],
        sourceApplication: String?,
        capturedAt: Date = Date()
    ) throws -> UUID
}
```

Tests cover valid rendered page, missing preprocessing result, over-limit XHTML, empty Readability result, and a writer failure that must not report success.

- [ ] **Step 2: Verify test failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleShareCaptureHandlerTests
```

Expected: missing handler.

- [ ] **Step 3: Build the Safari preprocessing adapter**

Start `ArticleCapturePreprocessor.js` with the exact vendored Readability 0.6.0 bytes, followed by an adapter that:

```javascript
var ExtensionPreprocessingJS = new function () {
  this.run = function (arguments) {
    var clone = document.cloneNode(true);
    var article = new Readability(clone, {
      maxElemsToParse: 50000,
      keepClasses: false
    }).parse();
    var payload = article ? {
      sourceURL: document.location.href,
      canonicalURL: document.querySelector("link[rel='canonical']")?.href || null,
      title: article.title || null,
      byline: article.byline || null,
      siteName: article.siteName || null,
      language: article.lang || document.documentElement.lang || null,
      publishedTime: article.publishedTime || null,
      excerpt: article.excerpt || null,
      contentXHTML: article.content || "",
      textContent: article.textContent || "",
      imageURLs: Array.from(
        new DOMParser().parseFromString(article.content || "", "text/html").images
      ).map(function (image) { return image.currentSrc || image.src; }).filter(Boolean)
    } : null;
    arguments.completionFunction({ echoArticleCapture: payload });
  };
};
```

Add a verification step to `verify_readability_vendor.sh` proving the combined file begins byte-for-byte with the pinned upstream file before the marked Echo adapter.

- [ ] **Step 4: Implement the extension controller**

Use `NSExtensionJavaScriptPreprocessingResultsKey` from a property-list attachment. The same target supports `iphoneos`, `iphonesimulator`, and `macosx`; `ShareViewController` conditionally subclasses `UIViewController` or `NSViewController`. It shows **Saving to Echo…**, calls the pure handler, then shows **Saved to Echo** only after `stage(_:)` succeeds and completes the extension request. Failure shows **Could not capture article** and cancels with the bounded error.

The extension:

- bundle ID `com.echo.audiobooks.share`;
- extension point `com.apple.share-services`;
- App Group `group.com.echo.audiobooks`;
- deployment iOS 18/macOS 15;
- activation for Safari webpage/property-list and URL inputs;
- no CloudKit entitlement and no credential access.

Embed the extension in both `Echo` and `Echo macOS` host products and include it in their schemes' build graph.

- [ ] **Step 5: Run handler tests and host builds**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleShareCaptureHandlerTests
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
bash Scripts/verify_readability_vendor.sh
```

Expected: the extension compiles for both host schemes and tests pass. Simulator build success is not Safari acceptance.

- [ ] **Step 6: Commit**

```bash
git add "Echo Share Extension" Echo.xcodeproj/project.pbxproj Scripts/verify_readability_vendor.sh EchoTests/ArticleWorkshop
git commit -m "feat: capture Safari articles into Echo"
```

---

