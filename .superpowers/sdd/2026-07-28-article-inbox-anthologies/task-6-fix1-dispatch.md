# Task 6 fix round 1

Resume Task 6 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base task commit:

`ee5b6b72`

The adversarial reviewer found two Critical and seven Important defects independent of the known Task 5 resource dependency. Fix them test-first. The missing bundled Readability source remains deferred; do not touch the Xcode project or duplicate the vendor source.

## Critical

1. **WebKit is not actually network-silent.**
   - Block `document` loads as well as images/styles/scripts/fonts/media/raw/SVG.
   - Install an explicit navigation policy that permits only the one initial supplied-document navigation and cancels iframe document loads, meta refresh, popup/new-window requests, link navigation, and every subsequent navigation.
   - Treat content-rule compilation/navigation-policy failure as fail-closed.
   - Add deterministic policy/subresource regressions without real internet traffic.

2. **URLSession delegate isolation is unsafe under default Main Actor isolation.**
   - Make the lock-protected loader/delegate explicitly `nonisolated` (or every witness nonisolated with explicit actor hops where required).
   - Keep all mutable delegate state behind the lock and retain `@unchecked Sendable` only with a documented invariant that the code actually satisfies.
   - Add a real injected-URLProtocol callback execution test, not only a warning-free compile.

## Important

3. **WebKit cancellation can leave script continuations pending.**
   - Store and gate navigation, parser-script, and payload-script continuations.
   - Cancellation must resume the active continuation exactly once with `CancellationError`, stop navigation, and ignore every late callback.
   - Add deterministic cancellation/late-callback tests through narrow seams.

4. **Image total-byte budget does not bound network transfer.**
   - Before each request, compute the remaining total budget.
   - Limit that loader to `min(maxSingleImageBytes, remainingTotalBytes)`.
   - Stop requesting candidates when the total budget is exhausted; do not continue downloading arbitrary over-budget responses.
   - Test request count and chunked boundaries at remaining-budget exhaustion.

5. **Image destination write has a check/write overwrite race.**
   - Use a contained temporary file plus a genuinely atomic no-overwrite publish, or an equivalent exclusive/no-replace primitive.
   - Revalidate root/destination containment and non-symlink state at publication.
   - Preserve an existing destination and clean task-owned temporary residue on every failure.
   - Add a pre-existing/racing-destination regression.

6. **Image type/properties do not prove complete decodability.**
   - Require ImageIO source status to be complete and perform a bounded actual decode after dimension/pixel validation.
   - Reject truncated or malformed JPEG/PNG that exposes a UTI/properties.
   - Add authored tiny valid JPEG/PNG fixtures and truncated variants.

7. **Authentication classifier is overly broad and not “dominated by.”**
   - Match login/auth path components or exact boundaries; `/author/...` must not match `/auth`.
   - Use conservative structural signals/ratios so one incidental password field or heading does not discard a readable article, while a login-dominated document returns the exact Safari message.
   - Add false-positive and dominated-login tests.

8. **Injected additional headers can carry credentials.**
   - Clear `httpAdditionalHeaders` and construct/sanitize the effective ephemeral configuration so injected protocol classes remain usable but Authorization/cookie/custom stored headers cannot be sent.
   - Add a protocol test inspecting the received request headers.

9. **Image warnings/readable state are not durably integrated.**
   - Add the smallest explicit integration through `ArticleInboxIngestionService` that persists the sanitized content state and combined deterministic sanitizer/localization warnings into the capture record without weakening durable-file → DB-row → identity-bound cleanup.
   - Image failure must preserve readable blocks/text, persist a warning, and produce review-suggested rather than capture-failed when text remains usable.
   - The test must exercise this single integrated path; sanitizing an unrelated fixture is insufficient.
   - Do not invent a broad pipeline abstraction. If an overload or narrow processing method is needed to preserve Task 3’s synchronous recovery tests, keep it explicit and minimal.

## Minor

10. Follow redirects using a request rebuilt with the normalized redirect URL rather than validating then following the unnormalized original request.

## Required adversarial proof

Add or strengthen tests for:

- sixth redirect, relative redirect, normalized redirect, credential/scheme rejection;
- chunked twelve-MiB response cutoff and real delegate callbacks;
- cleared injected Authorization/cookie/custom headers;
- conservative login false positive plus dominated login;
- WebKit policy/content-rule and cancellation once-only behavior;
- remaining-total image budget request count;
- MIME/type agreement, complete decode, truncation, dimensions, atomic no-overwrite, containment;
- durable combined warning/state and later snapshot load with zero refetch.

Preserve:

- explicit fail-closed `vendoredSourceUnavailable` until Task 5 bundles the pinned source;
- no real network access in tests;
- Task 3 quarantine/recovery invariants and Task 4 typed sanitizer;
- no cookies, credentials, request/response headers, browser data, or active content persisted.

Stay within the Task 6 files plus the already-listed `ArticleInboxIngestionService.swift` and Task 6 test files. Modify an existing Task 3 test only if a signature-compatible adjustment is strictly required. Do not touch the project, share extension, vendor source, narration files, or `ARCHITECTURE.md`.

Run one Task 6 Xcode command from this worktree at a time:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- any focused ingestion integration suite you add
- `git diff --check`

Commit subject:

`fix: harden local article capture`

Append “Fix round 1” to `task-6-report.md`, map every finding to code/tests, preserve the Task 5 dependency and receipt boundaries, and return the short status contract.
