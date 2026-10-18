# Task 3 implementer dispatch

You are implementing Task 3: atomic staging, durable capture storage, and crash-safe Article Inbox ingestion.

Read this first — it is your complete task specification:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-brief.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Context and binding decisions:

- Base commit is `b7793161`. Tasks 1 and 2 are complete. Reuse `ArticleCaptureEnvelope`, `ArticleWorkshopLimits`, `ArticleCaptureRecord`, `ArticleCaptureDAO`, and the repository's existing file-location/database patterns.
- The `complete` marker is the package commit record. Encode and validate before publishing the final package; partial packages must remain invisible to the importer. Write the marker last.
- Preserve the required ordering: durable Application Support snapshot first, database row second, staging deletion last. Design the exact retry path for the crash window where the durable file exists but the row was not yet inserted.
- Verification is fail-closed: require the marker, require directory UUID and envelope UUID agreement, require the supported schema version, enforce byte bounds, and verify SHA-256 before publishing `snapshot.json`.
- If the database already contains the capture UUID, only treat it as recovered success when the durable package exists and its digest matches. Otherwise report an error and retain the complete staging package.
- Use injected temporary roots in tests. Never write tests into real Application Support, App Group, or iCloud locations.
- Apply iOS complete-until-first-user-authentication protection to the staged directory. Keep macOS/watchOS compilation safe using the repository's platform-conditional patterns; do not weaken the requested iOS protection.
- Use CryptoKit for SHA-256 and explicit typed or descriptive errors. Do not suppress I/O, decoding, digest, database, or deletion failures with `try?`.
- Preserve deployment floors iOS 18, macOS 15, watchOS 11; Swift 6 strict concurrency; and default Main Actor isolation. The extension-safe writer must retain the specified `nonisolated` interface.
- `Shared`, `EchoCore`, and `EchoTests` are file-system-synchronized groups for these locations. Do not modify `Echo.xcodeproj/project.pbxproj`.
- The Global Pronunciation sibling owns narration files, the project file, and `ARCHITECTURE.md`; do not read-modify or touch them.
- Make no changes outside the files named in the brief. Preserve unrelated worktree and sibling state.
- Follow strict TDD: write all six failure/recovery/idempotency tests first, run and record a meaningful RED result, then write the smallest implementation. Run test commands serially—never start overlapping Xcode test processes.
- The existing whole-suite baseline is independently red/environmentally unstable. Do not alter or reinterpret it. Your proof obligation is `make build-tests` plus both focused suites in the brief.

Before committing, self-review:

- Atomic visibility and marker-last ordering.
- Correct cleanup and residue after success, incomplete package, and every failure.
- No row can point to a missing durable snapshot.
- Exact-once logical ingestion across retry, including durable-file-before-row recovery.
- UUID, schema, size, and digest validation at every trust boundary.
- File protection is applied to the intended staged package on iOS.
- No credentials, cookies, authorization headers, form data, browsing history, scripts, frames, or embeds are persisted.

Commit with the exact subject:

`feat: stage article captures atomically`

Write the detailed report to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-report.md`

The report must include implementation details, files changed, self-review, exact RED and GREEN commands with relevant output, and concerns. Return only the short status contract: status, commit SHA/subject, one-line test summary, concerns, and report path.
