# Task 2 report — Article Workshop persistence

## Implementation

Implemented the V37 `v37_article_workshop` GRDB migration and registered it immediately after V36. It adds the five specified Article Workshop tables, all required keys and foreign-key deletion policies, plus indexes for capture date, canonical (normalized) URL, revision parent, anthology entry display order, and anthology build revision.

Added Codable/GRDB record types for captures, revisions, anthologies, entries, and build receipts. `ArticleCaptureRecord` consumes the existing `ArticleCaptureMethod`; it does not duplicate that enum.

Added focused capture and anthology DAOs. Writer closures provide the single GRDB transaction for each multi-step mutation: revision/current-revision updates, stable-slot allocation plus `next_stable_slot` increment, complete entry reorder, and build save plus latest revision update. No `INSERT OR REPLACE` or GRDB `.replace` is used.

## Files changed

- `Shared/Database/Migrations/Schema_V37.swift`
- `Shared/Database/DatabaseService.swift`
- `Shared/Database/ArticleWorkshopRecords.swift`
- `Shared/Database/DAOs/ArticleCaptureDAO.swift`
- `Shared/Database/DAOs/AnthologyDAO.swift`
- `EchoTests/ArticleWorkshop/SchemaV37ArticleWorkshopTests.swift`
- `EchoTests/ArticleWorkshop/ArticleWorkshopDAOTests.swift`

## Tests and evidence

Tests were authored before the production files.

### RED

Required commands run immediately after adding the tests:

`make test-only FILTER=EchoTests/SchemaV37ArticleWorkshopTests`

`make test-only FILTER=EchoTests/ArticleWorkshopDAOTests`

The repository's `test-only` target expands to `xcodebuild test-without-building`; it does not compile newly added test sources. Therefore it could not produce the brief's expected missing-record/migration compiler diagnostics from the test-first state. This is an execution limitation of that target, not treated as passing RED evidence. The first compiled test run then correctly exposed the initial nested-transaction implementation error: `Caught error: SQLite error 1: cannot start a transaction within a transaction`.

The writer already owns the transaction, so the nested transaction calls were removed while retaining all affected operations within their writer closures.

### GREEN

`make build-tests`

`make test-only FILTER=EchoTests/SchemaV37ArticleWorkshopTests`

`make test-only FILTER=EchoTests/ArticleWorkshopDAOTests`

`git diff --check`

Results:

- `make build-tests`: `** TEST BUILD SUCCEEDED **`.
- `SchemaV37ArticleWorkshopTests`: iPhone 17 simulator xcresult reports 1 passed, 0 failed.
- `ArticleWorkshopDAOTests`: iPhone 17 simulator xcresult reports 4 passed, 0 failed.
- `git diff --check`: no output (clean).

## Self-review

- Migration is additive and registered as the immutable V37 migration.
- `article_revision` and anthology-owned rows cascade with their owners; `anthology_entry.capture_id` restricts capture deletion, exercised by the schema test.
- Stable slots are selected and incremented in the same writer transaction, are never decremented, and the lifecycle test proves A/B -> remove A -> C yields B/C slots 1/2 even when ordered C/B.
- Reordering validates an exact, duplicate-free entry set and changes only `sort_order`, never `stable_slot`.
- `latestSuccessfulBuild` filters to successful status and orders by revision, so a later failed build cannot replace the latest successful receipt.
- All data-bearing SQL uses statement arguments; database errors propagate.

## Concerns

- `make test-only` cannot supply the requested compile-time RED evidence because it intentionally runs a prebuilt test bundle. A future strict-TDD workflow needs `make build-tests` (or a dedicated compile-only target) after test creation.
- Xcode emitted repeated discovery warnings for a passcode-protected physical device while the configured iPhone 17 simulator tests ran. No physical device interaction was attempted; the final simulator xcresults are green.

## Fix round 1 — stale anthology counters

### Finding

`AnthologyDAO.save` previously used record-wide `save`, allowing a stale
`AnthologyRecord` to overwrite the database-managed `next_stable_slot` and
`latest_build_revision` counters.

### Fix

`save` now performs an ID-targeted GRDB upsert. New anthologies insert all
record values, while a conflict updates only user-editable metadata: title,
subtitle, creator, cover path, and modified timestamp. It leaves created time
and both DAO-managed counters stored in the database untouched. It does not use
replace semantics.

Added `savingStaleAnthologyDoesNotRegressManagedCounters`, which allocates and
removes slot 0, records build revision 5, saves the original stale anthology,
then proves the next capture receives slot 1, the stored next slot is 2, and
the build revision remains 5.

### RED

`make build-tests`

`make test-only FILTER=EchoTests/ArticleWorkshopDAOTests`

The focused simulator result was 4 passed, 1 failed. The new regression failed
as expected with: `Expectation failed: (entryB.stableSlot → 0) == 1`.

### GREEN

`make build-tests`

`make test-only FILTER=EchoTests/ArticleWorkshopDAOTests`

`git diff --check`

The build succeeded and the focused simulator result was 5 passed, 0 failed.
`git diff --check` produced no output.

### Self-review and concerns

The conflict target is the anthology primary key; managed counters and
`created_at` are omitted from the update assignments, so stale records cannot
lower them. No schema changes or deferred schema-introspection work were made.
