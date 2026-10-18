# Task 4 implementer dispatch

You are implementing Task 4: sanitize captured XHTML into immutable typed blocks and apply non-destructive edit recipes.

Read this complete task specification first:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-brief.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base commit:

`cd2ff5e9`

Binding implementation decisions:

- Reuse `ReadabilityCapturePayload`, `ArticleCaptureEnvelope`, `ArticleWorkshopLimits`, and the canonical JSON/digest conventions from Tasks 1–3. Do not duplicate capture types.
- The trust boundary is hostile XHTML. Use `XMLParser` only as a streaming structural reader. Set `shouldResolveExternalEntities = false`; never instantiate/render WebKit content, evaluate scripts, resolve entities, fetch subresources, or preserve arbitrary markup.
- The malicious fixture must contain every attack named in the brief: scripts, forms, iframe, inline event handlers, `javascript:`, `file:`, oversized data URLs, and an external-entity declaration. Tests must prove none becomes executable/output markup.
- Accept only the exact structural vocabulary represented by `ArticleBlockKind`. Emit plain text and normalized values, never a generic HTML/DOM escape hatch.
- URL policy is fail-closed: allow only normalized absolute `http`/`https`; resolve relative links/images against the source URL before scheme validation; reject credentials and all unknown/active/local schemes. Images remain candidates, never fetched or embedded.
- Enforce centralized block/image candidate bounds during parsing, not after building an unbounded structure. Accumulate explicit warnings and derive the specified readiness state without swallowing parser errors.
- Assign IDs exactly once as `article-<capture UUID>-b<stable ordinal>`. Excluding or trimming blocks must never renumber survivors.
- Define all Task 4 domain values as immutable/`Sendable` where required and make Codable behavior deterministic under Swift 6 strict concurrency/default Main Actor isolation.
- `ArticleRevisionService` validates every referenced ID and trim ordering before applying changes. Apply trim boundaries before exclusions, preserve base order, overlay metadata without mutating the snapshot, and make reset reproduce the original block sequence.
- SHA-256 snapshots from canonical sorted-key JSON. Hash a clean revision only from readable/spoken content, with explicit deterministic separators/encoding so ambiguous concatenations cannot collide structurally.
- Do not add dependencies. Do not modify the Xcode project, narration files, `ARCHITECTURE.md`, Task 3 storage/ingestion files, or unrelated code.
- `Shared` and `EchoTests` use file-system-synchronized groups for these paths.

Follow strict TDD:

1. Add authored structural and malicious XHTML fixtures plus all eight required tests before production code.
2. Run and record a meaningful RED build/test result.
3. Implement the smallest domain model, sanitizer, and revision service satisfying the contract.
4. Run build and focused commands serially. Do not overlap Xcode processes or wait indefinitely on the locked physical device.

Self-review:

- No executable markup or active/local URL can survive.
- External entities cannot resolve and no network/file read is triggered.
- Bounds are applied before unbounded allocation/growth.
- Parser failure is visible and maps to review/failure state as specified.
- Stable IDs, trim/exclusion order, metadata overlays, reset, and hashes are deterministic.
- Fixtures are authored and DRM-free; no copied article body or private user data.

Verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleBlockSanitizerTests`
- `make test-only FILTER=EchoTests/ArticleRevisionServiceTests`
- `git diff --check`

Commit with:

`feat: sanitize article snapshots into blocks`

Write the detailed report to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-report.md`

The report must include files, model/security decisions, authored fixture inventory, exact RED/GREEN evidence, self-review, and concerns. Return only the short status contract.
