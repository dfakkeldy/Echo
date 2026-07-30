# Task 7 quality fix round 2

Resume Task 7 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`3a1c8dae`

Fix the five confirmed quality findings test-first. Keep the round bounded to Task 7 behavior and the smallest DAO/ingestion isolation changes necessary.

## 1. Atomic anthology seed creation — Important

Current anthology and entry writes use separate transactions.

- Add a cohesive DAO operation that creates the anthology and all selected entries in one `DatabaseWriter.write` transaction.
- Validate captures and insert ordered entries inside the same transaction.
- Allocate deterministic sort orders/stable slots and leave `nextStableSlot` equal to the committed entry count.
- Any constraint, missing-capture, or injected/later-entry failure must roll back the anthology, every entry, and counters.
- Add a valid RED rollback test. A duplicate capture ID that fails a later unique constraint is acceptable if it exercises the real production transaction path.
- Preserve Task 2's managed-counter rule; do not regress `AnthologyDAO.save`.

## 2. Reload work must not block MainActor — Important

`reload()` currently calls staging ingestion and database fetch synchronously on MainActor.

- Move production staging enumeration/import/cleanup and inbox/anthology database reads off MainActor through a bounded Sendable worker seam.
- `reload()` remains MainActor for observable state only: set `isImporting`, await the worker, then apply one result.
- Remove `@MainActor` from `ArticleInboxIngestionService` only if required and safe; preserve its Task 3/6 behavior and focused suites.
- Do not use unstructured fire-and-forget tasks. Cancellation and errors must return to the awaiting reload.
- Add a deterministic test proving reload suspends/yields while injected background work is blocked, so the importing state can render and another MainActor task can run.
- Preserve the required `ArticleInboxViewModel(db:fileStore:)` initializer and a simple test seam without a protocol hierarchy.

## 3. Deletion commit point and residue/UI consistency — Important

Define the database deletion as the logical commit point:

- Before DB commit, any failure restores the exact owned package.
- Re-check “unreferenced” atomically with deletion inside the database transaction so a concurrent new anthology reference cannot be cascaded away.
- After DB commit, failure to remove the safe quarantine must not report the capture as undeleted. Keep the quarantine as bounded, recognizable cleanup residue and retry safe cleanup on a later service load/reconciliation.
- Reconciliation may remove only a regular non-symlink quarantine entry with a canonical `<capture UUID>-<nonce UUID>` name whose capture row is absent. Unsafe/unrecognized entries fail closed.
- After successful logical deletion, the view model removes the article and its selection immediately before any reload. If subsequent ingestion/reload fails, the last successful list must remain accurate (deleted article absent) while showing the error.
- Add real production-path tests for:
  1. failure before DB commit restores package and row;
  2. cleanup failure after DB commit returns logical success, leaves safe residue, and later reconciliation removes it;
  3. a reference appearing before the transactional delete causes refusal and package restoration;
  4. reload failure after logical delete does not resurrect stale UI/selection.

A narrowly scoped injectable cleanup hook/file operation for deterministic failure tests is acceptable. Do not build a general filesystem abstraction.

## 4. Stable warning identity — Minor

- Do not use warning text as `ForEach` identity.
- Give each warning occurrence a stable per-render/index identity so repeated identical warning strings render separately.
- Keep VoiceOver text unchanged.

## 5. Accessibility Dynamic Type mode selector — Minor

- At accessibility Dynamic Type sizes, replace the non-reflowing three-segment presentation with an adaptive native picker/menu/list-style alternative that exposes the same three modes and current selection.
- At standard sizes retain the native segmented picker under the Library title.
- Preserve a minimum 44-point target, visible text, VoiceOver label/value/hint, and no custom motion.
- Add a small source/policy or extracted-policy test that proves the accessibility-size branch exists and maps all modes; do not add snapshot infrastructure.

## Verification

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
make test-only FILTER=EchoTests/LibraryViewModelTests
git diff --check
```

Run any new focused policy suite. Record only tests that actually execute; host/simulator exits before execution are not behavioral receipts.

No changes to the project file, narration files, architecture, share extension, Task 6 classifier, Task 8 Mac view, Task 9 editor, or Task 10 builder.

Commit:

`fix: harden article inbox transactions`

Append “Quality fix round 2” with RED/GREEN and failure-injection receipts to `task-7-report.md`. Return only when committed, clean, and complete.
