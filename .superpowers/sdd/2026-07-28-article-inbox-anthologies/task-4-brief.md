### Task 4: Sanitize extracted XHTML into immutable typed blocks

**Files:**
- Create: `Shared/ArticleWorkshop/ArticleWorkshopModels.swift`
- Create: `Shared/ArticleWorkshop/ArticleBlockSanitizer.swift`
- Create: `Shared/ArticleWorkshop/ArticleRevisionService.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleBlockSanitizerTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleRevisionServiceTests.swift`
- Create fixtures: `EchoTests/Fixtures/ArticleWorkshop/*.xhtml`

**Interfaces:**
- Consumes: `ReadabilityCapturePayload`, `ArticleWorkshopLimits`.
- Produces: `ArticleSnapshot`, `ArticleBlock`, `ArticleMetadata`, `ArticleEditRecipe`, `CleanArticle`.

- [ ] **Step 1: Add malicious and structural fixture tests**

Tests must prove:

```swift
@Test func keepsHeadingsParagraphsListsQuotesCodeImagesAndCaptions() throws
@Test func stripsScriptsFormsFramesEventHandlersAndHiddenActiveContent() throws
@Test func rejectsJavaScriptFileAndUnknownSchemes() throws
@Test func resolvesRelativeHTTPLinksAgainstSourceURL() throws
@Test func boundsBlockAndImageCandidateCounts() throws
@Test func malformedXHTMLBecomesReviewSuggestedWithoutExecutingAnything() throws
@Test func blockIDsRemainStableWhenCleanupExcludesNeighbors() throws
@Test func resetReturnsTheOriginalBlockSequence() throws
```

The malicious fixture includes `script`, `form`, `iframe`, `onclick`, `javascript:`, `file:`, oversized data URLs, and XML external-entity declarations.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleBlockSanitizerTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
```

Expected: missing sanitizer and domain types.

- [ ] **Step 3: Add canonical domain values**

```swift
enum ArticleBlockKind: String, Codable, Sendable {
    case heading, paragraph, listItem, quote, code, image, separator
}

struct ArticleBlock: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let stableOrdinal: Int
    let kind: ArticleBlockKind
    let text: String?
    let sourceURL: URL?
    let imageCandidateURL: URL?
    let caption: String?
    let codeLanguage: String?
}

struct ArticleEditRecipe: Codable, Equatable, Sendable {
    var excludedBlockIDs: [String]
    var trimBeforeBlockID: String?
    var trimAfterBlockID: String?
    var metadataOverrides: ArticleMetadataOverrides
}
```

Create block IDs as `article-<capture UUID>-b<stable ordinal>` once during initial sanitation. Never renumber after cleanup.

- [ ] **Step 4: Implement a fail-closed `XMLParser` sanitizer**

`ArticleBlockSanitizer.sanitize(envelope:)` must:

- set `shouldResolveExternalEntities = false`;
- accept only the structural elements represented by `ArticleBlockKind`;
- keep text values, not arbitrary DOM;
- normalize only `http`/`https` URLs;
- convert `img` into image candidates rather than embedded active markup;
- stop at centralized bounds;
- derive `Ready`, `Review suggested`, or `Capture failed` from usable text and warnings;
- SHA-256 the canonical sorted-key JSON snapshot.

`ArticleRevisionService.apply(snapshot:recipe:)` validates all referenced block IDs, applies trim boundaries before exclusions, preserves base order, overlays metadata, and hashes only readable/spoken content.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleBlockSanitizerTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
```

Expected: pass; no fixture output contains executable markup.

- [ ] **Step 6: Commit**

```bash
git add Shared/ArticleWorkshop EchoTests/ArticleWorkshop EchoTests/Fixtures/ArticleWorkshop
git commit -m "feat: sanitize article snapshots into blocks"
```

---
