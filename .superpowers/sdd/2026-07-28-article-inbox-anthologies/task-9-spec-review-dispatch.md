# Task 9 specification review

Review Task 9 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Read:

- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-review-package.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-brief.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-report.md`

Range:

- base `403924f6`
- head `b4f53793`

Adjudicate Task 9 specification compliance:

1. secure local snapshot loading from the exact managed package, digest/ID verification, no packagePath authority, network, WebKit, image download, or CloudKit;
2. current revision recipe becomes the baseline and preview is recomputed through `ArticleRevisionService`;
3. exclude/restore, inclusive trim before/after, metadata correction, reset, deterministic excluded IDs, and accurate `hasUnsavedChanges`;
4. no arbitrary prose replacement API, `TextEditor`, HTML editor, or base snapshot mutation;
5. save creates an immutable child revision with canonical recipe/metadata JSON, correct parent/device/hash;
6. insert plus current-pointer update is atomic and conditional on the expected base, with typed sibling conflict, rollback, and unsaved recipe preservation;
7. on-demand iOS cleanup route is real, keeps excluded rows visible/restorable, and offers structural context/swipe/VoiceOver actions plus metadata sheet/save/reset/conflict state;
8. Task 7 Inbox/navigation behavior remains intact; no Task 8/10, project, narration, share-extension, architecture, or Task 6 work entered.

Inspect actual source/tests. Treat build and 40-test counts as implementer receipts; do not rerun Xcode. Identify missing/extra/contradicted behavior with severity and file/line evidence.

Return exactly:

- `SPEC PASS` with concise evidence if compliant; or
- `SPEC FAIL` followed by findings ordered by severity with file/line evidence and the violated requirement.
