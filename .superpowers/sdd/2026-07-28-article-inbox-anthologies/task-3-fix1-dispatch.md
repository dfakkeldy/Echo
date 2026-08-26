# Task 3 fix round 1

Resume Task 3 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base task commit:

`079153b468f0b249af8fbc354c1910352587f88b`

The specification/quality reviewer found the following confirmed issues. Fix all Critical and Important findings with regression tests first. Address the Minor test gaps wherever needed to prove those fixes.

## Critical

1. `Shared/FileLocations.swift:45-47` uses process-local Application Support for capture staging. The Safari extension and host app therefore do not share the inbox.
   - Build `articleCaptureStagingDirectory()` beneath `try appGroupContainer()`.
   - Keep accepted Article Workshop storage in host Application Support.
   - Add a precise location contract test if an existing injectable/static test pattern supports it without touching real storage.

## Important

2. `ArticleInboxIngestionService` treats an existing row as recovered success based only on `contentSHA256`.
   - Compare every deterministic persisted field derived from the envelope and import result: identity, source/canonical URL, title, capture time, capture method, extractor version, package path, digest, and expected initial state as appropriate.
   - Fail closed and retain staging on any mismatch.
   - Write a regression test proving same digest with conflicting metadata/path is not accepted and staging remains.

3. `ArticleCaptureStagingWriter` can strand `.<UUID>.partial` or an incomplete `<UUID>` directory and permanently block same-UUID retry.
   - Add deterministic failure injection or another narrow test seam.
   - Clean attempt-owned partials after ordinary errors.
   - On retry, safely identify and reconcile stale incomplete packages without overwriting a complete package.
   - Prove retry after interruption both before and after final-directory publication.

4. `ArticleWorkshopFileStore` reads the full untrusted envelope before checking the byte limit.
   - Require a regular, non-symlink file.
   - Inspect file size before allocation and reject oversized data.
   - Use a bounded/read-and-revalidate approach sufficient to fail safely if the file changes during validation.
   - Add an oversized-input regression test.

5. Package traversal/cleanup validates only directory/existence properties and can follow symlinks.
   - Enumerate only direct UUID-named children of the standardized staging root.
   - Standardize and prove containment.
   - Reject symlinked package directories and symlinked marker/envelope files.
   - Require marker and envelope to be regular files with the marker contract expected by the design.
   - Revalidate the exact package before deletion so path substitution cannot redirect cleanup.
   - Add malformed-path/symlink tests where the platform test environment permits them.

## Minor proof gaps

- Strengthen tests around interruption/collision, metadata conflict, oversized input, malformed marker, and symlink packages/files.
- The successful-state marker test cannot observe chronological ordering by itself; use a failure point immediately before marker creation or a similarly deterministic seam to prove a published-but-incomplete package is ignored and retryable.

Binding constraints:

- Preserve the Task 3 interfaces and the durable-file → DB-row → staging-delete ordering.
- Retain complete staging on every validation, destination-write, database, or recovery mismatch failure.
- Do not weaken iOS complete-until-first-authentication protection.
- Make no changes outside the six Task 3 files unless a new Task 3 test file is strictly necessary. Do not touch the Xcode project, narration files, or architecture document.
- Run Xcode/build/test commands serially.
- Do not reinterpret incomplete focused xcresult receipts as test-runtime proof; report exact evidence.

Required verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- Any additional focused suite you add
- `git diff --check`

Commit the focused fixes with:

`fix: harden article capture handoff`

Append a “Fix round 1” section to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-report.md`

Report each finding as addressed or still open, list regression tests, provide exact GREEN evidence, and return the short status contract.
