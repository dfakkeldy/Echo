# Task 9 specification fix round 1

Resume Task 9 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`b4f53793`

Fix only the confirmed Important normalization gap, test-first.

- A loaded baseline recipe may contain duplicate and out-of-source-order `excludedBlockIDs`.
- Normalize every accepted recipe at the cleanup view-model boundary to:
  - only known source block IDs;
  - no duplicates;
  - exact immutable `source.blocks` order.
- Unknown IDs must continue to fail closed through existing validation; do not silently drop hostile unknown references.
- The normalized recipe is the editor baseline and the value used for preview, mutation comparison, and later save.
- A metadata-only edit after loading `[b2, b0, b2]` must publish `[b0, b2]`, assuming source order `b0, b1, b2`.
- Do not rewrite the existing stored revision merely by opening it; normalization is persisted only on an explicit save.

Add the regression before production change and record valid RED/GREEN. Preserve trim bounds, metadata, parent/current conflict behavior, hash semantics, and all previously accepted Task 9 behavior.

Verify:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCleanupViewModelTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/ArticleInboxPresentationPolicyTests
git diff --check
```

No project, narration, architecture, share-extension, Task 6/8/10, or arbitrary prose-editor changes.

Commit:

`fix: normalize article cleanup recipes`

Append “Specification fix round 1” with RED/GREEN receipts to `task-9-report.md`. Return only when committed and clean.
