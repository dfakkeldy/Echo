# Task 7 quality fix round 3

Resume Task 7 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`87abbecc`

Fix only the two new Important findings, test-first.

## 1. Overlapping reload stale-result race

Current detached reload work can finish out of order, publish stale lists, and clear `isImporting` while a newer reload remains active.

- Replace or wrap the detached worker with structured, awaited semantics. A dedicated actor worker is acceptable and preferable to fire-and-forget tasks.
- Give each `reload()` invocation a monotonically increasing generation/token.
- Only the latest generation may publish articles, anthologies, selected-ID pruning, success/error state, or clear `isImporting`.
- An older success or failure completing after a newer reload/deletion must be ignored for observable state.
- Forward cancellation into background work and add bounded cancellation checkpoints between staging packages / before expensive fetch phases where practical. Never publish a cancelled result.
- Preserve off-Main-Actor filesystem/database work and MainActor-only observable state.
- Add deterministic regressions:
  1. first reload blocks, second starts, first completes, `isImporting` remains true and stale results do not publish;
  2. second/latest completes and becomes the final list;
  3. an older reload finishing after a successful logical deletion cannot resurrect the deleted article or selection;
  4. cancellation cannot publish an error or clear a newer reload's importing state.

Do not add a general task manager or protocol hierarchy.

## 2. Owned-root validation and bounded quarantine scan

Current reconciliation validates `.DeletionQuarantine` but not `fileStore.root`, and `contentsOfDirectory` allocates/processes an unbounded residue set.

- Before reconciliation, require `fileStore.root` itself and the quarantine root to be regular non-symlink directories at their exact standardized paths.
- Enumerate direct quarantine children through a streaming/bounded mechanism; do not allocate the entire directory unbounded.
- Set one explicit production maximum for residue entries per reconciliation pass. A small internal initializer override is allowed for tests.
- Collect at most `limit + 1` without mutation, then fail closed if over limit. Do not partially clean an over-limit set.
- Preserve canonical `<capture UUID>-<nonce UUID>` validation, regular non-symlink child validation, and “capture row must be absent.”
- Add deterministic tests:
  1. symlinked `fileStore.root` is rejected and nothing in its target is removed;
  2. an over-limit set is rejected before any residue is removed;
  3. at-limit valid residue still reconciles;
  4. existing unrecognized-name failure remains green.

## Verification

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
make test-only FILTER=EchoTests/LibraryViewModelTests
make test-only FILTER=EchoTests/ArticleInboxPresentationPolicyTests
git diff --check
```

Record only executable test counts. Preserve every previously accepted Task 7 finding and do not touch the project file, narration, architecture, share extension, Task 6 classifier, Task 8, Task 9, or Task 10.

Commit:

`fix: serialize article inbox reloads`

Append “Quality fix round 3” with RED/GREEN and cancellation/bounds receipts to `task-7-report.md`. Return only when committed, clean, and complete.
