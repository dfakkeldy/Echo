# Task 7: Article Inbox and Library mode selector

Implement Task 7 from:

`docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base:

`daf7e4ea`

## Coordination and scope

- Do not modify `Echo.xcodeproj/project.pbxproj`, `ARCHITECTURE.md`, any narration file, the Safari share-extension directory, or the Global Pronunciation sibling worktree.
- Task 5 remains `WAITING_FOR_DEPENDENCY`.
- Task 6 has green local suites but two unresolved Important HTML-classifier findings after five fix rounds. Do not depend on, modify, or claim that classifier as accepted. Task 7 consumes already-ingested records/packages only.
- No iPhone Mirroring or physical-device work. Simulator/headless build and focused tests are allowed.
- Do not implement Task 8 Mac parity, Task 9 structural editing, or Task 10's full anthology builder. The Task 7 seed is deliberately minimal.
- Do not introduce third-party dependencies or a new generalized repository/service layer.

## Test-first requirements

Add the planned service and view-model tests before production code:

1. Inbox orders newest first with deterministic ID tie-break and maps `ready`, `reviewSuggested`, and `captureFailed` into explicit presentation states.
2. `reload()` drains complete staging packages before fetching.
3. Duplicate status is a nonblocking warning and preserves a clear Keep Both path; it is not a deduplication/delete action.
4. Multi-selection creates a minimal anthology seed and entries without opening Task 10 editing. Preserve a deterministic order derived from the visible inbox order.
5. Referenced deletion returns all affected anthology/project names and does not delete DB or package.
6. Unreferenced deletion removes both the database row and only its owned durable package.
7. Add adversarial deletion tests: a forged/out-of-root package path and a symlinked capture package must fail closed without removing arbitrary files or the DB row.
8. View-model selection must prune IDs no longer present after reload; `selectAll()` toggles predictably, and errors never discard the last successfully loaded list.

Run the focused suites in RED and record real executable failures. Simulator/tool-host exits before test execution are not behavioral receipts.

## Domain/service behavior

Create the planned `LibraryMode`, inbox item/state/deletion-impact models, `ArticleInboxService`, and `ArticleInboxViewModel`.

- Use existing `ArticleCaptureDAO`, `AnthologyDAO`, `ArticleInboxIngestionService`, and `ArticleWorkshopFileStore`.
- The required `ArticleInboxViewModel(db:fileStore:)` initializer must exist. A small internal injection initializer is allowed for deterministic tests; do not add a protocol hierarchy.
- `reload()` is MainActor-safe, sets `isImporting`, drains staging first, then fetches. It must not perform image downloads, CloudKit work, or network access.
- Decode warnings defensively. Unknown content-state strings should present as failed/review-needed rather than ready.
- Duplicate detection is warning-only. The source/canonical URL and digest are evidence, never authorization to merge or delete.
- Seed creation should create the minimal `AnthologyRecord` plus entries required by the current schema. Do not implement immutable build manifests or editing here.

For package deletion:

- Resolve the expected durable directory exactly as `<fileStore.root>/Captures/<capture UUID>`.
- Require the record path to equal that standardized location, remain beneath the owned root, and be a regular non-symlink directory.
- Do not follow symlinks or delete a path supplied only by the database.
- Preserve recoverability across file/database failure with a narrowly scoped quarantine/restore flow; do not leave a referenced or DB-visible capture with its package silently lost.
- If the capture is referenced, return project names and do not mutate anything.

## iOS UI and accessibility

Create:

- `LibraryModePicker`
- `ArticleInboxView`
- `ArticleDetailView`

Mount them in iOS `LibraryView` with Books / Inbox / Anthologies under the existing Library title.

- Existing shelf content, empty state, Browse By, Library Options, and Add Folder must remain Books-only.
- Inbox shows loading, empty, ready/review/failed states, duplicate warning, selection, New Anthology, Clean Up route, and deletion confirmation.
- Task 9 owns the structural editor. In Task 7, Clean Up may route to article detail and clearly indicate that cleanup is on demand; do not add arbitrary text editing or mutate article prose.
- Anthologies mode may show a bounded project list/placeholder backed by current records; do not implement Task 10 builder behavior.
- Preserve Dynamic Type, VoiceOver labels/traits, semantic buttons, minimum 44-point interactive targets, non-color-only state communication, and reduced-motion-safe behavior.
- Prefer native SwiftUI navigation, lists, confirmation dialogs, and segmented picker semantics. Do not add a custom design system.

## Verification

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/LibraryViewModelTests
git diff --check
```

Also run any focused source-policy/accessibility test you add. A simulator build is local compilation evidence only, not physical-device or Safari acceptance.

## Commit and report

Commit only the Task 7 implementation with:

`feat: add article inbox to Library`

Write an ignored report to:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-7-report.md`

Include:

- RED receipts;
- implementation summary;
- GREEN build/test counts;
- explicit security and accessibility checks;
- exact changed files;
- remaining proof boundaries.

Return only when committed, clean, and complete, or report an exact blocker without broadening scope.
