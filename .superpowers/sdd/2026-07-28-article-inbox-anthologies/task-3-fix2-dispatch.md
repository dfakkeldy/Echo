# Task 3 fix round 2

Resume Task 3 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`f05af11702e488af46df6f478ed24a9221c046a9`

The scoped re-review cleared findings 1–4 and most of findings 5–6. One Important deletion-identity gap remains.

## Open Important finding

`ArticleInboxIngestionService` calls `validateEnvelope(at:)` before cleanup but discards the validation result. A package can be replaced after import with another valid same-UUID envelope; validation succeeds and the replacement is deleted even though its digest differs from the imported snapshot.

Fix this narrowly:

- Bind cleanup to `imported.sha256`; no package may be deleted unless its final validated digest equals the exact bytes imported.
- Close the path-replacement race by atomically renaming the direct-child package to a unique, hidden quarantine/cleanup path in the same staging root before final validation and deletion.
- Validate the quarantined package and compare its digest to `imported.sha256`.
- Delete only the quarantined path after that exact match.
- If quarantine, validation, or digest matching fails, preserve the complete package under a recoverable path whenever safely possible and propagate the error. Never delete mismatched or unvalidated content.
- A newly created package at the original UUID path after quarantine must not be touched by cleanup.
- Keep direct-child containment and non-symlink checks at both the original and quarantined path.

## Required regression proof

Write tests first using a narrow deterministic cleanup hook or equivalent seam:

- replace the original package with different valid same-UUID bytes immediately before cleanup; drain must fail and retain the replacement;
- prove a newly created package at the original UUID path after quarantine is not removed when the accepted quarantined package is cleaned;
- exercise `.beforeFinalPublication` or complete-package collision preservation if it can be done without broadening production machinery.

Preserve all prior Task 3 contracts:

- durable snapshot → DB row → staging cleanup ordering;
- App Group staging and private Application Support durability;
- canonical bytes/digest behavior;
- file protection, strict concurrency, privacy limits, and public interfaces.

Stay within the six Task 3 files. Do not touch the Xcode project, narration files, or architecture document. Run build/tests serially and report runtime receipts accurately.

Verification:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `git diff --check`

Commit subject:

`fix: bind article cleanup to imported bytes`

Append “Fix round 2” to `task-3-report.md`, map the open finding and proof, and return the short status contract.
