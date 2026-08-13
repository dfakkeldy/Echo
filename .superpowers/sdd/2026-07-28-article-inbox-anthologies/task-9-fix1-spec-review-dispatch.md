# Task 9 specification fix round 1 review

Re-review the sole Task 9 specification finding in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Read:

- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-fix1-review-package.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-report.md`

Range:

- base `b4f53793`
- head `a9c433a3`

Adjudicate whether a valid loaded recipe such as `[b2, b0, b2]` is normalized to known IDs in immutable source order with no duplicates, becomes the in-memory baseline/preview/save recipe, and is persisted only on explicit save. Confirm unknown IDs still fail closed and other recipe fields remain unchanged.

Treat tests as receipts; do not rerun Xcode. Return exactly:

- `SPEC PASS` with concise file/line evidence; or
- `SPEC FAIL` with the remaining/new finding and evidence.
