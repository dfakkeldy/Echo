# Task 3 fix round 3

Resume Task 3 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`8eba57f2`

The reviewer confirms deletion identity is addressed but found one new Important crash-recovery gap: a crash/error after the package moves into `.cleanup-*` but before deletion leaves quarantine residue that future drains ignore.

Fix this narrowly and test-first:

- At the start of `drainStaging()`, discover only safe, direct-child `.cleanup-*` directories below the standardized non-symlink staging root.
- Validate the cleanup-root naming/shape and require exactly the intended real, non-symlink UUID-named package child (or safely recognize an empty cleanup root).
- Reconcile a nonempty quarantined package only when all three identities agree:
  1. the quarantined envelope/digest;
  2. the existing durable `snapshot.json` bytes/digest;
  3. the complete deterministic existing `ArticleCaptureRecord`.
- Delete the quarantined package/root only after that agreement. Retain mismatched, malformed, unvalidated, missing-row, or missing/mismatched-durable content and propagate an error; do not silently report a clean drain.
- Remove a safe empty cleanup root as harmless post-delete residue.
- Do not touch a current direct UUID package while reconciling its prior quarantine.
- Preserve containment, non-symlink checks, digest identity, and the durable snapshot → DB row → cleanup ordering.

Required regressions:

- Throw at `.afterQuarantine`, verify the first drain leaves quarantine, then create a fresh service without the throwing hook and verify the next drain reconciles the matching quarantine and leaves no cleanup residue.
- Seed or mutate quarantined content so its digest/metadata does not match durable storage/the row; the retry must fail and retain it.
- Cover safe empty-cleanup-root removal.
- Retain the prior proof that a newly staged original UUID package is not deleted while the earlier quarantined package is reconciled.

Do not broaden the API or introduce general cleanup infrastructure. Stay within the Task 3 service/tests unless a tiny existing Task 3 helper adjustment is essential. Do not touch the Xcode project, narration files, or architecture document.

Run serially:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `git diff --check`

Commit subject:

`fix: reconcile quarantined article captures`

Append “Fix round 3” to `task-3-report.md`, preserving the execution-evidence boundary, and return the short status contract.
