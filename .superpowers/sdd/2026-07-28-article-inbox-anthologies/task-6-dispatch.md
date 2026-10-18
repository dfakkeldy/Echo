# Task 6 implementer dispatch

You are implementing Task 6: URL-only article capture, network-silent Readability extraction, and safe image localization.

Read this complete task specification first:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-brief.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base commit:

`f3226d42`

Task 5 is deferred because its required project file is owned by the active Global Pronunciation sibling. Task 6 is intentionally proceeding independently and must not touch the share-extension directory or Xcode project.

Binding networking/security decisions:

- Use an injected `URLSession` built from ephemeral configuration for HTTP(S). Disable persistent cookies, credential storage, and caching; never persist request/response headers, cookies, authorization, or credentials.
- Accept only normalized `http`/`https` input and revalidate every redirect target. Stop after at most `ArticleWorkshopLimits.maxRedirects`; reject scheme changes to anything else.
- Enforce `maxURLResponseBytes` incrementally in the URLSession delegate before unbounded `Data` allocation. Cancel promptly at the limit and surface a bounded explicit error.
- Require a successful HTTP response and an HTML/XHTML MIME type. Do not infer arbitrary binary content as HTML.
- Login/authentication classification must be deterministic and conservative using the specified password/sign-in/known-login-path signals. Return exactly:
  `authenticationRequired(message: "Open this page in Safari to capture the signed-in version.")`
- Do not preflight reachability or use Network.framework; this is HTTP and belongs on URLSession.
- Cancellation must cancel URLSession/WebKit work, resume continuations exactly once, and release delegates/tasks without leaks or double callbacks.

Binding WebKit decisions:

- `ReadabilityWebExtractor` is Main Actor-bound where WebKit requires it.
- Use a nonpersistent `WKWebsiteDataStore`.
- Page-authored JavaScript stays disabled. Install a content rule that blocks every subresource load before loading the already-fetched HTML with the source URL as base.
- Evaluate only the exact pinned vendored Readability source plus a narrow extraction adapter in the client content world.
- Do not load the original URL in WebKit and do not refetch on later snapshot load.
- Return the same `ReadabilityCapturePayload` contract established in Task 1.

Binding image decisions:

- Normalize candidates to credential-free HTTP(S) URLs and use the injected ephemeral network boundary.
- Count only accepted assets toward `maxImages`; enforce `maxSingleImageBytes` while reading and `maxTotalImageBytes` before publication.
- Accept only response MIME and decoded bytes that agree as JPEG or PNG. Use ImageIO without eager full-size rendering; validate nonzero, bounded decoded dimensions/pixel arithmetic before accepting.
- Use deterministic local names, atomic writes inside the capture directory, and never overwrite or escape that directory.
- A failed/rejected image adds a warning but cannot discard or downgrade otherwise readable text to capture failure.

Task 3/4 integration:

- Reuse `ReadabilityCapturePayload`, `ArticleSnapshot`, `ArticleWorkshopFileStore`, sanitizer warning/state types, and centralized limits. Do not duplicate domain models.
- `ArticleInboxIngestionService` changes must preserve its proven durable-file → DB-row → identity-bound quarantine cleanup protocol.
- No later snapshot load may perform a network request. Tests must prove the stored/localized representation is self-contained.

Follow strict TDD:

1. Add the seven required tests using an injected `URLProtocol` and authored in-memory fixtures before production code.
2. Obtain a meaningful RED receipt.
3. Implement the smallest production code.
4. Run only one Task 6 Xcode command from this worktree at a time. Unrelated sibling builds may coexist and must not be touched.

Do not add dependencies. Do not modify the Xcode project, share extension, narration files, `ARCHITECTURE.md`, or files outside the Task 6 list.

Self-review:

- Redirect and response-size bounds cannot be bypassed.
- No cookies, credentials, auth headers, or response headers are persisted.
- WebKit cannot originate network/subresource requests.
- Cancellation completes exactly once.
- MIME, decoded type, dimensions, bytes, total bytes, destination containment, and atomicity are all verified.
- Every test uses injected networking; no real internet access.

Verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- `git diff --check`

Commit with:

`feat: add local URL article capture`

Write the detailed report to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Include files, trust-boundary design, exact RED/GREEN receipts, self-review, and concerns. Return the short status contract.
