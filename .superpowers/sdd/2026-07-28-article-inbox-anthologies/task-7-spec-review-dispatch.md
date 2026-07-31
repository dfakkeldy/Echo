# Task 7 specification review

Review Task 7 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Read:

- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-7-review-package.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-7-brief.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-7-report.md`

Range:

- base `daf7e4ea`
- head `735ba1e0`

This is specification compliance review, not a broad style review. Inspect actual source/tests and adjudicate:

1. Inbox ordering and explicit Ready / Review Suggested / Failed presentation, including fail-closed unknown states.
2. `reload()` drains complete staging before fetch, does no network/image/CloudKit work, and retains the last successful list on error.
3. Duplicate evidence is warning-only and Keep Both remains available.
4. Multi-selection deterministically creates only a minimal anthology seed/entries without Task 10 editing/build behavior.
5. Referenced deletion returns affected project names and does not mutate file/DB state.
6. Unreferenced deletion removes DB and only the exact owned durable package with a recoverable failure path; forged/out-of-root and symlink packages fail closed.
7. Selection pruning/toggling and required `ArticleInboxViewModel(db:fileStore:)` API.
8. iOS Library mounts Books / Inbox / Anthologies; existing shelf content/actions are Books-only; Inbox exposes selection, New Anthology, duplicate warning, Clean Up route, and deletion confirmation; Anthologies remains bounded.
9. Task 9 structural editing, Task 8 Mac parity, project/narration files, Safari extension, and Task 6 classifier remain out of scope.
10. Planned focused tests exist and support the claimed behavior.

Treat build and test counts as implementer receipts; do not rerun Xcode. Identify missing, extra, or contradicted plan behavior with Critical/Important/Minor severity and file/line evidence. Do not broaden into implementation-quality concerns unless they demonstrate specification noncompliance.

Return exactly:

- `SPEC PASS` with concise evidence if compliant; or
- `SPEC FAIL` followed by findings ordered by severity, each with file/line evidence and the violated requirement.
