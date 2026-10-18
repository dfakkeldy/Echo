# Task 9 quality fix round 2

Resume Task 9 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`a9c433a3`

Fix the three confirmed Important findings test-first.

## 1. Bind snapshot validation to one file identity

The current size-before/after check misses atomic same-size replacement and same-inode same-size rewrite.

- Open `snapshot.json` once and read through that handle.
- Use descriptor metadata before and after reading to require:
  - regular file;
  - same device/inode;
  - unchanged size;
  - unchanged high-resolution modification and change metadata.
- After reading, `lstat`/equivalent the live path without following a leaf symlink and require it is still the same regular device/inode as the opened handle.
- Preserve exact root/Captures/package ancestry validation, byte bound, SHA-256, schema, and capture-ID checks.
- Close the handle on every path.
- A narrowly scoped validation hook is allowed for deterministic race tests; do not introduce a filesystem abstraction.
- Add valid RED/GREEN tests for:
  1. atomic replacement with different same-length bytes after the read;
  2. same-inode same-size rewrite after the read;
  3. unchanged file still loads.

Both races must throw `fileChangedDuringValidation` (or an equally typed safe error), never return stale bytes.

## 2. Make trim state visible and accessible

Rows outside the retained trim bounds currently look included.

- Extract a deterministic per-block presentation state from the cleanup model/policy:
  - included;
  - explicitly removed;
  - trimmed above;
  - trimmed below;
  - clear “starts here” / “ends here” boundary indicators where applicable.
- The original source order and restorable removed rows remain visible.
- Trimmed rows must be visibly and semantically marked as not included; do not rely on color.
- Give VoiceOver a state value/label that distinguishes removed, trimmed above, trimmed below, and included.
- Keep structural actions available where meaningful and do not mutate prose.
- The preview must make retained content verifiable: either render the actual retained block list or provide equivalent explicit retained/trimmed row state plus clear boundaries. Prefer the smallest native SwiftUI presentation.
- Add model/policy tests for before-boundary, boundary, inside, after-boundary, and explicit exclusion within retained bounds.

## 3. User-safe errors and retry

Raw filesystem paths and GRDB/internal diagnostics must not reach UI.

- Map loading failures to stable, localized-ready user messages:
  - missing article;
  - invalid saved cleanup;
  - original capture could not be read safely;
  - generic temporary load failure.
- Never interpolate paths, URLs, SQL, record IDs, or raw underlying diagnostics.
- Loading failure UI must include a minimum-44-point **Try Again** action that clears terminal state and re-runs the same capture load. A retry must not spawn overlapping loads or publish a stale earlier result.
- Map save failures:
  - typed revision conflict keeps the existing actionable conflict copy;
  - all other database/internal errors become a generic retryable message explicitly saying the unsaved choices remain.
- Preserve cancellation as silent and preserve unsaved recipe/conflict state.
- Add tests for hostile errors containing a private path and GRDB/SQL-like text; asserted user messages must contain neither. Add a deterministic retry-state test (or a small testable load-state coordinator) proving one retry starts a new load and stale prior completion cannot overwrite it.

Do not solve this with broad global error infrastructure.

## Verification

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCleanupViewModelTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/ArticleInboxPresentationPolicyTests
git diff --check
```

Run any new cleanup presentation/loading policy suite. Record only executable test counts.

Preserve Task 9 specification and every accepted Task 7 behavior. No project, narration, architecture, share-extension, Task 5/6/8/10, network, CloudKit, or prose-editor changes.

Commit:

`fix: harden article cleanup validation`

Append “Quality fix round 2” with RED/GREEN race, retry, privacy, and accessibility receipts to `task-9-report.md`. Return only when committed and clean.
