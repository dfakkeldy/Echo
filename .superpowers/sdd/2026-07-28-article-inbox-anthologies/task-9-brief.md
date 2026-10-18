# Task 9: Reversible on-demand structural cleanup

Implement Task 9 from:

`docs/superpowers/plans/2026-07-28-article-inbox-anthologies.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Base:

`403924f6`

## Coordination and scope

- Do not modify `Echo.xcodeproj/project.pbxproj`, `ARCHITECTURE.md`, narration files, the share extension, or the Global Pronunciation sibling worktree.
- Task 5/8 remain dependency-waiting. Task 6 remains review-blocked. Do not modify or claim them.
- No iPhone Mirroring or physical-device work.
- Structural cleanup is explicitly on demand. Do not auto-clean during capture, Inbox reload, article open, anthology seed creation, or build.
- Do not implement Task 10 anthology builder, Task 11 EPUB, Task 14 narration, arbitrary article prose editing, HTML editing, or a general document editor.
- No third-party dependency or generalized repository/protocol hierarchy.

## Test-first required behavior

Add `ArticleCleanupViewModelTests` before production code. Cover:

1. exclude and restore a block;
2. trim before/after while retaining valid inclusive bounds;
3. metadata correction;
4. reset to the immutable raw snapshot;
5. no arbitrary article-text replacement API and no `TextEditor` in the cleanup surface;
6. save creates an immutable child revision with canonical recipe/metadata JSON, parent revision, device name, and preview readable hash;
7. saving when the database current revision changed since load returns a typed conflict and does not insert/publish the stale sibling;
8. successful save updates the editor baseline and clears `hasUnsavedChanges`;
9. excluded rows remain addressable/restorable in source order;
10. malformed current-revision JSON or a revision belonging to another capture fails closed.

Also add focused storage/DAO tests for exact package ownership and conditional revision publication.

## Immutable snapshot loading

The durable capture package contains `snapshot.json` with the original `ArticleCaptureEnvelope`.

- Add the smallest cohesive `ArticleWorkshopFileStore` load API needed for an existing capture.
- Resolve the package only as `<fileStore.root>/Captures/<capture UUID>`.
- Require the workshop root, `Captures`, package directory, and snapshot file to be exact regular non-symlink paths.
- Read through the existing envelope byte bound and require the stored SHA-256 to match `ArticleCaptureRecord.contentSHA256`.
- Never trust `packagePath` as deletion/read authority and never follow a database-supplied arbitrary path.
- Decode with `JSONDecoder.articleWorkshop`, require capture-ID agreement, and sanitize locally with `ArticleBlockSanitizer`.
- No network/refetch, WebKit, image download, CloudKit, or credential access.
- Perform file/database loading off MainActor through a bounded actor/Sendable loader; only observable editor state and SwiftUI presentation belong on MainActor.

If a current revision exists, decode its recipe and use it as the editor baseline. Recompute preview through `ArticleRevisionService`; never trust a stored rendered copy.

## Atomic revision conflict boundary

Add a cohesive conditional DAO operation rather than a view-model check-then-save race:

- insert the new revision and update `article_capture.current_revision_id` in one database transaction;
- require the current pointer to equal the editor's expected base revision, including `nil`;
- on mismatch, roll back the inserted revision and return a typed sibling/conflict result;
- set `parentRevisionID` to the expected base;
- do not mutate or delete the concurrent revision.

Keep existing `saveRevision` behavior intact for its established callers/tests.

## View-model contract

Implement the planned:

```swift
@MainActor @Observable
final class ArticleCleanupViewModel {
    private(set) var source: ArticleSnapshot
    var recipe: ArticleEditRecipe
    var preview: CleanArticle
    var hasUnsavedChanges: Bool

    func exclude(blockID: String)
    func restore(blockID: String)
    func trimBefore(blockID: String)
    func trimAfter(blockID: String)
    func updateMetadata(_ overrides: ArticleMetadataOverrides)
    func reset()
    func save(deviceName: String?) throws -> ArticleRevisionRecord
}
```

- Every mutation recomputes preview exclusively through `ArticleRevisionService`.
- Unknown IDs are ignored or surfaced safely; never corrupt the recipe.
- Keep excluded IDs deterministic in source order with no duplicates.
- Resolve conflicting trim bounds predictably without crashing or silently producing invalid order.
- `hasUnsavedChanges` compares against the loaded/saved baseline recipe, not merely “recipe is nonempty.”
- A save conflict remains visible/actionable and preserves the user's unsaved recipe.

## iOS structural editor and accessibility

Create `ArticleCleanupView` and wire the existing on-demand **Clean Up** route from `ArticleDetailView` to real loading/editing.

The UI:

- renders all source blocks in original order;
- uses Remove / Restore, **Trim everything above**, and **Trim everything below**;
- keeps excluded rows visible in a collapsed/restorable form;
- provides a metadata correction sheet;
- shows preview/save/reset state and a clear concurrent-revision conflict;
- does not include a `TextEditor` or any arbitrary prose replacement control;
- never edits the base snapshot.

Provide:

- native buttons, list/context/swipe actions;
- equivalent VoiceOver custom actions for remove/restore and trim;
- non-color-only excluded/unsaved/conflict states;
- semantic headers, unbounded Dynamic Type text, and minimum 44-point interactive targets;
- a confirmation before discarding unsaved cleanup if the navigation pattern requires it;
- no custom animation requiring a Reduce Motion alternative.

Pass only the narrow cleanup context through the accepted Inbox/detail navigation. Preserve all Task 7 Books/Inbox/Anthologies behavior and toolbar isolation.

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

Run any focused cleanup accessibility/source-policy suite added. Record only actual executable test counts; simulator/tool-host exits before tests execute are not behavioral receipts.

## Commit and report

Commit:

`feat: add reversible article cleanup`

Write ignored report:

`.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-9-report.md`

Include RED/GREEN receipts, exact files, conflict/failure-injection evidence, security/accessibility checks, and remaining proof boundaries. Return only when committed and clean, or with an exact blocker.
