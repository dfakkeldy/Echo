# Task 6 report: bounded URL capture and image localization

## Status

Code complete with a deferred Task 5 integration dependency. The URL/session and
image-localization boundaries are implemented and tested with injected
`URLProtocol` fixtures. Default production Readability extraction is deliberately
fail-closed until Task 5 packages the already-pinned
`ThirdParty/Readability/Readability.js` into the app bundle. No project-file
change or duplicate JS source was made in this task.

## Files

- `EchoCore/Services/ArticleWorkshop/ArticleURLCaptureService.swift`
- `EchoCore/Services/ArticleWorkshop/ReadabilityWebExtractor.swift`
- `EchoCore/Services/ArticleWorkshop/ArticleImageDownloader.swift`
- `EchoTests/ArticleWorkshop/ArticleURLCaptureServiceTests.swift`
- `EchoTests/ArticleWorkshop/ArticleImageDownloaderTests.swift`
- `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxIngestionServiceTests.swift`

## Trust boundaries

- HTTP(S) requests start from injected ephemeral configurations with cookies,
  credential storage, URL caching, persistent response state, and injected
  additional headers disabled.
  URLs and every redirect are normalized and credential-free; redirect handling
  stops before a sixth follow.
- A `URLSessionDataDelegate` validates successful HTTP and allowed MIME types
  before accepting bytes, counts bytes incrementally, cancels at the central
  twelve-MiB response cap, and completes/cancels its continuation once while
  invalidating its session/delegate relationship.
- Login classification is conservative and deterministic: exact login path
  components, password inputs, sign-in/login headings, and low article-signal
  dominance yield the required Safari message rather than a stored article.
- WebKit uses a nonpersistent store, disabled page JavaScript, a document and
  subresource blocking rule, supplied HTML only, and the client content world.
  Navigation policy permits one supplied main-frame document only; later links,
  iframe loads, refreshes, and popups are cancelled. Its parser
  source is injectable for controlled callers; the production provider looks
  only for a packaged Readability resource and otherwise throws the explicit
  `vendoredSourceUnavailable` error. It never fetches the original URL.
- Image candidates must be credential-free HTTP(S). Each image uses only the
  remaining total budget, so requests stop before that budget is exhausted.
  Only JPEG/PNG MIME values whose complete ImageIO decoded type, dimensions,
  pixel arithmetic, and actual image decode agree are accepted. Accepted data
  is published through a contained temporary path and a non-replacing move; a
  rejected image contributes only a localization warning.
- After the proven staged-envelope -> durable-file -> database-row ->
  identity-bound-quarantine cleanup protocol completes, the ingestion overload
  persists sorted, prefixed sanitizer and image-localization warnings. Image
  failures retain readable text and produce `reviewSuggested`, never
  `captureFailed` merely because image localization failed.

## TDD and verification receipts

RED, before production services:

```text
make build-tests
... ArticleImageDownloaderTests.swift:19:26: error: cannot find
'ArticleImageDownloader' in scope
** TEST BUILD FAILED **
```

GREEN build after implementation and the Swift 6 test-protocol isolation fix:

```text
xcodebuild build-for-testing -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 5 \
  CODE_SIGNING_ALLOWED=NO -quiet
exit 0
```

Final focused execution, serial and injected only:

```text
xcodebuild test-without-building ... -only-testing:EchoTests/ArticleURLCaptureServiceTests ... -quiet
exit 0

make build-tests
** TEST BUILD SUCCEEDED **

make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
6 tests passed, 0 failures

make test-only FILTER=EchoTests/ArticleImageDownloaderTests
5 tests passed, 0 failures

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
14 tests passed, 0 failures

make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests
2 tests passed, 0 failures
```

An earlier quiet isolated invocation exited 0 while its result bundle showed a
test-host installation failure; it is intentionally excluded from verification.
The receipts above are the repository-supported shared build/test commands and
their completed simulator test runs. The ImageIO logs for intentionally invalid
fixture bytes are expected decoder diagnostics, not test failures.

## Self-review

- Response and image size limits are enforced during delegate receipt, before
  unbounded append/allocation.
- No request/response headers, cookies, credentials, authorization values, or
  browser state are persisted by the implementation.
- WebKit cannot navigate to the source URL and its loaded document cannot fetch
  subresources; a later sanitizer/snapshot load has no network code path.
- Delegate/session cancellation and every active WebKit navigation/parser/payload
  continuation are guarded to resume once; late callbacks are token-gated and
  ignored. A task cancelled between reader phases exits before installing a new
  continuation.
- MIME, decoded image type, dimensions, pixel multiplication, byte budgets,
  destination containment, and atomic/non-overwrite writes are checked.

## Concerns and required follow-up

Task 5 owns Xcode resource/project integration and is deferred. The current
Echo product bundle does not contain `Readability.js`, so default runtime URL
capture is **not runtime-functional yet** and will fail closed instead of
substituting a parser or downloading code. Task 5 must package the exact pinned
vendor file and then run an on-device/simulator extraction acceptance check.

## Fix round 1

- The loader is explicitly nonisolated with a documented lock invariant,
  clears injected persistent headers, and rebuilds redirects from normalized URLs.
- Login paths use exact components and a structural password/heading dominance
  check; ordinary article discussion of sign-in is not treated as a login page.
- Image requests use the remaining total budget; ImageIO requires complete
  status and an actual decode; tests cover request-count stopping, truncation,
  existing-file non-overwrite, temporary-file cleanup, and symlink containment.
- WebKit rules include document loads and navigation policy permits only the
  supplied initial document. Cancellation gates navigation, parser, and payload
  continuations exactly once; deterministic tests cover the policy, all blocked
  resource classes, cancellation, and late-callback seams without real traffic.
- `ArticleInboxIngestionService` now has a deliberately narrow post-import
  presentation update. It keeps recovery identity checks based on durable
  capture fields, so an enriched warning/state record remains safely retryable.
  The integrated regression proves readable text survives a failed image while
  persisted state becomes `reviewSuggested` with deterministic warning JSON.

## Fix round 2

Production edits for the four re-review findings preceded the newly required
regressions; this round makes no synthetic RED claim. The regressions then
exposed an enriched-record retry comparison defect and ImageIO tolerance of a
CRC-corrupted PNG; both were fixed before the final receipts.

- A single-flight extraction identity now tokens rule compilation, navigation,
  parser, and payload continuations. The production rule compiler is injectable
  for the cancellation test; late callbacks are ignored and a cancelled extractor
  can accept a later extraction. Navigation requires the active token and exact
  active WebView identity.
- Image validation keeps complete-source status and bounded immediate rasterization,
  then verifies PNG chunk ordering, bounds, and CRCs before acceptance. JPEG still
  requires SOI/EOI plus ImageIO type/status/decode checks.
- Enriched warning/state records are persisted before cleanup. An interruption
  after persistence retains staging; retry verifies immutable identity, preserves
  presentation fields, and finishes cleanup without a duplicate.

Final repository-supported receipts:

```text
make build-tests
** TEST BUILD SUCCEEDED **

make test-only FILTER=EchoTests/ArticleImageDownloaderTests
6 passed, 0 failed

make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
7 passed, 0 failed

make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests
4 passed, 0 failed

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
15 passed, 0 failed
```

## Fix round 3

Production edits and the new regressions evolved together in this round; this
report makes no synthetic RED claim. A focused delayed-cancellation test first
exposed an unbounded test scheduling wait, which was replaced with explicit,
one-second-bounded observations of A's compiler callback and delayed cancel,
B's callback, stale-A cancellation, and B's own cancellation/late callback.
The initial ImageIO-only corruption regression also became a genuine failure:
ImageIO logged a bad IDAT stream but still produced a drawable thumbnail. The
final zlib stream check closes that acceptance gap.

- Every scheduled WebKit cancellation carries its extraction UUID and only
  cancels work while that UUID remains active. The deterministic test proves a
  delayed cancel from completed extraction A cannot cancel replacement B.
- Image validation runs outside the main actor, uses a 512-pixel immediate
  raster bound, uses a lookup-table CRC, requires ordered IHDR/contiguous
  IDAT/IEND structure, and streams concatenated PNG IDAT through zlib with an
  8-KiB output buffer. It requires the expected scanline byte count,
  end-of-stream, all input consumed, and zlib checksum validation without
  retaining a full decoded raster.
- Login classification now requires an independent sign-in/authentication
  action in the password form. A password-strength educational form remains
  capturable, while a real login form inside article markup remains classified
  for Safari.
- Enriched warning/state presentation is saved before cleanup and ordinary
  recovery preserves it across both retained staging and post-quarantine
  reconciliation; neither retry creates a duplicate capture row.

Final repository-supported receipts:

```text
make build-tests
** TEST BUILD SUCCEEDED **

make test-only FILTER=EchoTests/ArticleImageDownloaderTests
7 passed, 0 failed

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
16 passed, 0 failed

make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
8 passed, 0 failed

make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests
5 passed, 0 failed

git diff --check
exit 0
```

## Fix round 4

The added compatibility regressions produced real RED evidence before the
production changes: a password-update submit was incorrectly classified as
login, and valid multi-buffer plus Adam7 PNGs were rejected. The Adam7 fixture
is authored with zlib in the test and asserts its IHDR interlace byte is `1`.

- Password forms now require login/auth/sign-in semantics on the form action,
  input/button/label, or heading itself; a generic submit control no longer
  implies authentication.
- PNG IDAT inflation now uses incremental `Z_NO_FLUSH` calls with a fixed
  8-KiB output buffer. It rejects no-progress/truncated iterations, allows
  progress-bearing `Z_BUF_ERROR`, and requires the exact output count,
  `Z_STREAM_END`, and all input consumed.
- Adam7 image data is accepted with overflow-safe exact accounting for all
  seven pass origins and strides. CRCs, IHDR/contiguous-IDAT/IEND ordering,
  zlib completion, and ImageIO/raster limits remain required.

Final repository-supported receipts:

```text
make build-tests
** TEST BUILD SUCCEEDED **

make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
10 passed, 0 failed

make test-only FILTER=EchoTests/ArticleImageDownloaderTests
9 passed, 0 failed

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
16 passed, 0 failed

make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests
5 passed, 0 failed

git diff --check
exit 0
```

## Fix round 5

The first executable focused run after adding the three new regressions was
genuine RED: the `/auth` action and nested button text captured rather than
returning authentication-required, while `class="login-demo"` caused a false
authentication result. Two earlier simulator-host exits occurred before test
execution and are not counted as behavioral evidence.

- Authentication path detection now parses only the form's `action` value and
  recognizes the bounded login/auth path-component set.
- Login wording is read only from the specified input/button attributes or
  normalized visible text of button, label, and heading elements. Arbitrary
  form/control attributes such as `class` are not considered.
- Visible text strips nested markup before whitespace normalization, so a
  nested `Log in` button is recognized. The outside-heading fallback remains
  limited to a leading login heading, preserving readable article discussion
  of signing in.

Final repository-supported receipts:

```text
RED: make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
13 tests run; 3 new authentication-classification regressions failed as expected.

make build-tests
** TEST BUILD SUCCEEDED **

make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
13 passed, 0 failed

make test-only FILTER=EchoTests/ArticleImageDownloaderTests
9 passed, 0 failed

make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
16 passed, 0 failed

make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests
5 passed, 0 failed

git diff --check
exit 0
```
