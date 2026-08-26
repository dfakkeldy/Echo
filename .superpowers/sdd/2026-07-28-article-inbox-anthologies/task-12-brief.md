# Task 12 — Atomic EPUB publication and Echo library import

## Frozen base

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Branch: `codex/article-anthology-design`
- Base: `387130c7274643b05288bf8f1b6ac22a93343828`
- Plan: `docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`, Task 12

Task 11’s text/cover EPUB builder and preflight are implemented and implementation-reviewed. Its specification remains `WAITING_FOR_DEPENDENCY` only because article image blocks have no upstream managed asset descriptor; such builds fail closed with `missingImageAssetMapping`. Task 12 must preserve any prior edition and record failure when the builder rejects such a manifest.

## Scope

Create/modify only:

- `EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift`
- `EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift`
- `EchoTests/ArticleWorkshop/AnthologyBuildServiceTests.swift`
- `EchoTests/ArticleWorkshop/AnthologyLibraryIntegrationTests.swift`

Small, demonstrated changes to existing Article Workshop DAO/model/service APIs and test helpers are allowed and must be reported.

Do not touch protected narration/project/ARCHITECTURE files, the sibling worktree, Task 13 generated-block identity, CloudKit, M4B, or physical devices.

## Required contract

Use TDD. Prove missing-service RED before production writes.

Implement an actor-isolated `AnthologyBuildService` that:

1. freezes one immutable `AnthologyBuildManifest`;
2. builds only into an exact direct-child temporary file `.book-<UUID>.epub` in the managed edition directory;
3. uses only frozen manifest/managed snapshot inputs and never performs network I/O;
4. requires the Task 11 builder/preflight receipt and independently verifies the staged regular file/digest before publication;
5. publishes at `ArticleWorkshop/Editions/<anthology UUID>/book.epub`;
6. imports/upserts a normal Echo `AudiobookRecord` using a stable explicit audiobook identity tied to the edition directory/final URL, not a temporary path;
7. records the successful anthology build and latest-success pointer only after file publication and import are coherent.

The operation spans filesystem plus database/import state. Failure at every injected point must:

- record a failed attempt without consuming the successful revision;
- leave the previous `book.epub` byte-for-byte intact if one existed;
- leave the previous successful receipt/latest pointer intact;
- leave the prior usable Books shelf record/import intact;
- remove only Task 12’s validated temporary/backup residue;
- never delete or follow a symlinked/non-owned destination.

If `EPUBImportCoordinator` requires the final URL before it can import with stable identity, use a tested backup/restore protocol around replacement. Do not claim atomicity by replacing the prior edition and leaving it replaced after a later import/DAO failure. Repeated success and retry after failure must be idempotent.

Validate exact anthology/revision/identifier/digest agreement among manifest, build result, final file, build receipt, and imported record. Keep raw diagnostics out of user-visible errors.

## UI/status

Add separate EPUB state:

- not built;
- building;
- ready(revision);
- changes available(builtRevision);
- failed(previousRevision?).

Expose **Build EPUB**, **Rebuild EPUB**, **Open in Echo**, and **Share EPUB** only when prerequisites are true. Keep narration/M4B status separate. Show fixed safe errors and allow retry/dismiss. Prevent stale overlapping build/load results from replacing newer state. Provide accessible non-color labels and progress.

## Required tests

At minimum:

- successful build atomically publishes and records ready;
- every failure point before/during/after replacement preserves previous EPUB, previous successful receipt/pointer, and usable library record;
- failed retry does not consume revision; next success uses the same revision;
- no network path exists or is invoked;
- temp/symlink/path substitution is rejected without external writes;
- receipt/digest/identity mismatch fails closed;
- stable audiobook identity across rebuilds;
- Books shelf title/creator/cover metadata;
- real integration through `EPUBImportCoordinator` for one generated text/cover anthology;
- Task 11 `missingImageAssetMapping` is recorded as failure and preserves the prior edition;
- UI status/actions and accessibility prerequisites;
- overlapping build/load state cannot publish stale results.

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyBuildServiceTests
make test-only FILTER=EchoTests/AnthologyLibraryIntegrationTests
```

Also run Task 10 service/builder, Task 11 builder/preflight, relevant importer/DAO regressions, formatting, `git diff --check`, and source privacy/network scans. Report simulator/bootstrap failures as unavailable, never passing.

Physical-device, external-reader, EPUBCheck, hosted CI, merge, install, and release remain pending.

## Review and commit

Self-review, commit a coherent implementation, then obtain separate read-only specification and adversarial implementation reviews against the exact frozen SHA. Same implementer fixes confirmed issues, maximum five rounds.

Report:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-12-report.md`

Commit subject:

`feat: import built anthologies into Echo`

Return exact SHA, clean state, tests, failure matrix, reviewer verdicts, and separate proof gates.
