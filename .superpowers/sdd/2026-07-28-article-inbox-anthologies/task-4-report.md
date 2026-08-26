# Task 4 report — sanitize article snapshots into blocks

## Delivered files

- `Shared/ArticleWorkshop/ArticleWorkshopModels.swift`
  - Immutable, `Codable`, `Equatable`, and `Sendable` typed block, metadata,
    snapshot, clean-article, warning, content-state, and edit-recipe values.
  - Canonical sorted-key JSON SHA-256 for snapshots and length-delimited UTF-8
    SHA-256 for readable/spoken revision content.
- `Shared/ArticleWorkshop/ArticleBlockSanitizer.swift`
  - Streaming `XMLParser` sanitizer with external entities disabled and no
    browser, WebKit, script evaluation, subresource fetch, or image fetching.
- `Shared/ArticleWorkshop/ArticleRevisionService.swift`
  - Validated trim/exclude application, immutable metadata overlay, and reset.
- `EchoTests/ArticleWorkshop/ArticleBlockSanitizerTests.swift`
- `EchoTests/ArticleWorkshop/ArticleRevisionServiceTests.swift`
- `EchoTests/Fixtures/ArticleWorkshop/structural.xhtml`
- `EchoTests/Fixtures/ArticleWorkshop/malicious.xhtml`
- `EchoTests/Fixtures/ArticleWorkshop/malformed.xhtml`

## Model and security decisions

- `ArticleBlockKind` is the complete emitted vocabulary: heading, paragraph,
  list item, quote, code, image candidate, and separator. The sanitizer never
  retains generic HTML, DOM nodes, attributes, event handlers, forms, or
  embedded resources.
- `XMLParser` is only used as a structural streaming reader, with
  `shouldResolveExternalEntities = false`. The parser does not instantiate a
  browser or perform any network/file action.
- Only normalized absolute `http`/`https` URLs survive. Relative URLs resolve
  against the capture source before validation. Credentials, `javascript:`,
  `file:`, data URLs, and unrecognized schemes are rejected. Images are URL
  candidates only; no image bytes are fetched or embedded.
- DOM element, block, and image-candidate limits are checked before appending
  each value. A limit aborts parsing with a deterministic warning; parser
  failures remain visible as warnings. Usable text plus no warnings is ready;
  usable text with any warning is review suggested; no usable text is capture
  failed.
- Block IDs are assigned once at sanitation as
  `article-<capture UUID>-b<stable ordinal>`. Revision application filters the
  original array after validated trim bounds, so it never renumbers survivors.
- Revision hashes use a version prefix plus length-delimited UTF-8 fields for
  kind, text, caption, and code language. This avoids ambiguous concatenation.

## Authored fixtures

- `structural.xhtml`: heading, paragraph/link, list items, quote, Swift code,
  image candidate/caption, and separator.
- `malicious.xhtml`: script, form/input, iframe, inline event attributes,
  `javascript:`, `file:`, unknown `gopher:`, a policy-oversized (all data URLs
  are rejected rather than parsed or retained) data URL, and an external XML
  entity declaration targeting `/etc/passwd`.
- `malformed.xhtml`: unclosed paragraph/document structure.

## TDD evidence

### RED

After tests and fixtures were added, `make build-tests` failed with the
expected missing Task 4 API errors: `ArticleSnapshot`, `ArticleBlock`,
`ArticleMetadata`, `ArticleEditRecipe`, `ArticleRevisionService`, and
`ArticleContentState` were not in scope. This was an expected compiler RED
before production code existed.

### GREEN

Final serial commands and receipts:

1. `make build-tests` — `** TEST BUILD SUCCEEDED **`.
2. `make test-only FILTER=EchoTests/ArticleBlockSanitizerTests` — complete
   xcresult `Test-Echo-2026.07.29_01-02-45--0300.xcresult`: 7 passed, 0 failed,
   0 skipped.
3. `make test-only FILTER=EchoTests/ArticleRevisionServiceTests` — complete
   xcresult `Test-Echo-2026.07.29_01-03-53--0300.xcresult`: 3 passed, 0 failed,
   0 skipped.
4. `git diff --check` — passed with no output.

An earlier focused sanitizer invocation overlapped a still-running
`build-for-testing` process. The newer PID was stopped immediately at the
coordinator's request; that incomplete invocation is not treated as a test
receipt. All final build/test evidence above was run strictly serially after
both prior Xcode PIDs had exited.

## Self-review

- No executable markup, active/local URL, image data, event handler, external
  entity value, form content, frame content, or arbitrary attribute can enter
  an `ArticleBlock` or the encoded snapshot.
- Parser bounds are enforced while parsing; no unbounded block/image output is
  constructed first and trimmed later.
- Parser failure maps to review/capture-failed state without silently dropping
  the failure signal.
- Tests cover all eight required named behaviors, plus ID validation, metadata
  overlays, deterministic readable hashes, and deterministic snapshot hashes.
- Only the requested Shared, EchoTests, and fixture paths were changed; the
  file-system-synchronized project groups require no Xcode project edit.

## Concerns

- This task implements only the typed sanitizer and in-memory revision service.
  Wiring snapshots/revisions into the persistence and UI workflow remains the
  responsibility of later article-workshop tasks.

## Fix round 1

### Findings addressed

1. **Qualified and unlisted active elements:** namespace processing is enabled
   and element names are normalized to local names. Only XHTML/no-namespace
   structural emitters, leaf values, and named transparent reading wrappers are
   admitted. Every other namespace or element begins a skipped subtree, so its
   descendants, attributes, text, captions, and URLs cannot reach an allowed
   ancestor. The regression exercises `evil:script`, `audio`, `video`, and
   `canvas` inside a paragraph.
2. **Rejected image candidates:** an image is retained and counted only after
   its source normalizes to an HTTP(S) candidate and block capacity is known.
   Missing, data, local, and other rejected sources create no image block and
   do not spend the candidate limit. The regression sends more than the image
   limit of rejected `file:` images before later paragraph text and a valid
   image candidate.
3. **Caption-only readability:** a figure with a non-empty caption and no
   retained image becomes one deterministic paragraph block. Readiness now
   recognizes text or captions, matching the clean readable-content hash.
4. **Proof gaps:** `malicious.xhtml` now references `&xxe;` in an allowed
   paragraph; tests assert neither entity/declaration text nor replacement
   bytes survive. The sanitizer test directly exceeds the DOM element limit.
   Revision tests prove spoken text, caption, and order affect the digest,
   while metadata, block IDs, and URLs do not.

### Fix-round TDD and serial receipts

- Valid RED: `Test-Echo-2026.07.29_01-16-53--0300.xcresult` ran the sanitizer
  suite with 7 passed, 4 failed, 0 skipped (unlisted subtree text,
  rejected-image exhaustion, caption-only readiness, and the fixture assertion
  updated for the entity probe).
- GREEN build: `make build-tests` completed with `** TEST BUILD SUCCEEDED **`.
- GREEN sanitizer: `Test-Echo-2026.07.29_01-27-48--0300.xcresult` — 11 passed,
  0 failed, 0 skipped.
- GREEN revision service: `Test-Echo-2026.07.29_01-30-11--0300.xcresult` — 5
  passed, 0 failed, 0 skipped.
- `git diff --check` passed with no output.

Two early focused-test attempts are excluded: one result bundle was corrupted
(missing `Info.plist`) and one test was stopped after a concurrent sibling
command began. The valid RED/GREEN receipts above were collected with only one
Task 4 Xcode process from this worktree active at a time.
