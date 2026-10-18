# Task 6 fix round 2

Resume Task 6 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`90e9d76f`

The scoped re-review cleared findings 1, 2, 4, 5, 8, 10 and parts of the proof gaps. Four areas remain. Fix them test-first without touching the Task 5 resource/project dependency.

## 1. WebKit cancellation and reuse — partially addressed

- Add a single-flight extraction identity/token. Concurrent or reentrant use of one extractor must fail deterministically rather than sharing mutable continuations.
- Token the rule-compilation and navigation phases as well as parser/payload evaluation.
- Rule compilation itself is not cancellable, but task cancellation must resume the waiting continuation exactly once with `CancellationError`; the eventual WebKit callback must be ignored by token.
- Navigation callbacks must verify both active extraction identity and exact `WKWebView` identity before resuming anything. Stale callbacks from a prior extraction cannot affect a later one.
- Cancellation during any phase must finish that phase exactly once, stop the active WebView, clear active identity, and ignore late callbacks.
- Add deterministic tests for:
  - cancellation during rule compilation;
  - stale navigation callback after a new extraction identity exists;
  - concurrent/single-flight rejection;
  - existing parser/payload late-callback gates.

## 2. Complete bounded image decode — partially addressed

- Do not rely on `CGImageSourceCreateImageAtIndex(... shouldCache: false)`, which may defer decompression.
- Force bounded immediate decoding, preferably with a thumbnail/raster path using `kCGImageSourceShouldCacheImmediately`, a strict maximum pixel dimension, and no unbounded full-size allocation.
- Retain complete-source status, MIME/UTI agreement, dimensions, and overflow checks.
- Add an authored complete-container image with corrupted compressed pixel data that metadata inspection accepts but forced decode rejects.

## 3. Login form dominance — partially addressed

- Replace raw global `<p|article|main>` tag counts with form-local structure.
- A form containing a password input plus login-specific heading/label/submit/action signals must classify as authentication-required even when the page has `<main>` and explanatory paragraphs.
- An ordinary article mentioning login or containing a non-dominant/incidental field must remain capturable.
- Keep exact login/auth path-component handling.
- Add both representative login-form and article false-positive/false-negative tests.

## 4. Warning/state crash recovery — Important

Current enrichment happens after `drainStaging()` has already removed the staged package. Move it into the recoverable per-package protocol:

- Derive the combined sorted warnings and presentation state before record persistence/cleanup.
- For a new row, save the enriched record before quarantine cleanup.
- For an existing matching imported row, persist/repair the enriched presentation fields before cleanup.
- If enrichment persistence fails, retain the complete staged package.
- If termination occurs after enriched row save but before cleanup, retry must recognize matching durable/import identity, preserve/confirm the enriched fields, and safely finish cleanup.
- Keep Task 3 identity matching based on immutable imported fields; do not let mutable presentation fields hide a content/package conflict.
- Preserve the existing no-enrichment `drainStaging()` behavior for Task 3 callers.
- Add a deterministic interruption test after enriched record persistence but before quarantine. Verify:
  - staged input remains after the first failure;
  - the database already contains `reviewSuggested` and deterministic warning JSON;
  - retry completes cleanup without refetch or duplicate row;
  - a persistence failure leaves staging and no false success.

## Remaining proof gaps

Strengthen tests so they exercise behavior rather than only pure helper strings where feasible:

- rule compilation/navigation cancellation and late callbacks through the real continuation state machine;
- incrementally delivered/chunked response over the twelve-MiB cap;
- stored/durable capture reload with zero URLProtocol requests;
- corrupted complete-container image requiring immediate decode;
- enrichment interruption/retry before cleanup.

Preserve:

- the repository-supported real receipts already obtained;
- default `vendoredSourceUnavailable` until Task 5 bundles exact pinned bytes;
- no real network in tests;
- one Task 6 Xcode command from this worktree at a time;
- no project, share extension, vendor, narration, or architecture changes.

Verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests`
- `git diff --check`

Commit subject:

`fix: close article capture recovery gaps`

Append “Fix round 2” to `task-6-report.md`, map each open finding and exact real receipts, and return the short status contract only after implementation, verification, and commit.
