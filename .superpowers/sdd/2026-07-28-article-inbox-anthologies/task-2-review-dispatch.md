# Task 2 specification and quality review

Review Task 2 first for exact specification compliance, then for migration, persistence, and test quality. This is task-scoped, not the final branch review.

## Requested work

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-brief.md`

Binding constraints:

- Preserve every exact V37 table, column, default, unique key, foreign key, and delete policy from the brief.
- Register `v37_article_workshop` immediately after V36; live `origin/nightly` still has V37 free.
- Capture deletion must be restricted while an anthology entry references it. Revision and anthology-owned rows use the specified cascades.
- Stable slots are monotonic per anthology, allocated and incremented atomically, never reused after removal, and unaffected by display reordering.
- A later failed build must not replace the latest successful build receipt.
- DAOs must expose the exact signatures in the brief, propagate errors, and parameterize data-bearing SQL.
- Do not use `INSERT OR REPLACE` or GRDB `.replace` for records with dependent rows because delete-then-insert can fire cascades.
- Preserve iOS 18, macOS 15, watchOS 11, Swift 6 concurrency, and Echo's existing GRDB architecture.
- Do not modify the Xcode project, narration files, or architecture document owned by Global Pronunciation.
- Tests were required before production code. The report states `test-only` could not compile newly added tests, so its two requested RED commands did not produce missing-symbol compiler diagnostics; the first compiled run instead failed on a real nested-transaction defect. Judge this evidence accurately without treating the unavailable command result as a pass.

## Implementer report

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-report.md`

Treat claims as unverified.

## Diff

- Base: `b68e039c06f53e6b9ff0ed07d073da39d889193a`
- Head: `105a03da`
- Package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-review-b68e039c..105a03da.diff`

Read the package once; it contains commits, stat, and full diff. Do not run git commands or crawl the codebase. Inspect unchanged code only for a specific named risk the diff cannot answer, and name that focused check.

This review is read-only. Do not mutate files, the index, HEAD, or branch. Do not rerun reported tests unless a specific unresolved code doubt requires one focused test.

## Output

Begin directly with:

### Spec Compliance

- `✅ Spec compliant` or `❌ Issues found`, with file:line evidence.
- List `⚠️ Cannot verify from diff` separately.

Then:

### Strengths

Concrete evidence with file:line references.

### Issues

Critical, Important, and Minor. For each: file:line, defect, impact, and fix direction.

### Assessment

- `Task quality: Approved` or `Task quality: Needs fixes`
- One or two sentences of technical reasoning.

Both spec and quality verdicts are mandatory.
