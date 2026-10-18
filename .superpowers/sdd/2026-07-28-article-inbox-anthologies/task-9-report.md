# Task 9 report: Reversible on-demand structural cleanup

## Outcome

Implemented an on-demand structural cleanup editor that always derives its preview from the immutable captured snapshot and publishes cleanup choices as immutable child revisions. The original capture is never edited. Concurrent publication uses one conditional database transaction and leaves a stale sibling uncommitted.

## RED receipts

1. Initial `make build-tests` failed with the new tests because `ArticleWorkshopFileStore.loadSnapshot`, `ArticleCaptureDAO.publishRevision`, `ArticleRevisionPublicationError`, and the cleanup editor types did not exist.
2. After the first implementation, `ArticleCleanupViewModelTests` executed 9 tests and failed only `conflictPreservesUnsavedRecipeAndDoesNotPublishStaleSibling`: editing after a save conflict erased the visible conflict marker. The marker is now cleared only by initialization or successful publication.
3. The non-technical conflict policy was added before the UI correction. `ArticleCleanupViewModelTests` executed 9 tests and failed only the source-policy assertion because the view displayed `Newer revision: <UUID>`. The internal identifier is no longer user-visible.

Simulator-host bootstrap exits that occurred before any test executed were treated as unavailable runs and were not counted as behavioral receipts.

## GREEN receipts

- `make build-tests`: `TEST BUILD SUCCEEDED` on the final source state.
- `ArticleCleanupViewModelTests`: 9 tests passed.
- `ArticleRevisionServiceTests`: 5 tests passed.
- `ArticleWorkshopFileStoreTests`: 8 tests passed.
- `ArticleWorkshopDAOTests`: 7 tests passed.
- `ArticleInboxViewModelTests`: 9 tests passed.
- `ArticleInboxPresentationPolicyTests`: 2 tests passed.
- Total focused executable receipt: 40 tests passed.
- `git diff --check`: passed.
- Strict Swift formatting lint passed for the new cleanup files and touched clean-format source files.

## Production files

- `EchoCore/ViewModels/ArticleCleanupViewModel.swift`
- `EchoCore/ViewModels/ArticleInboxViewModel.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleCleanupView.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleDetailView.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift`
- `Shared/ArticleWorkshop/ArticleWorkshopFileStore.swift`
- `Shared/Database/DAOs/ArticleCaptureDAO.swift`

## Test files

- `EchoTests/ArticleWorkshop/ArticleCleanupViewModelTests.swift`
- `EchoTests/ArticleWorkshop/ArticleWorkshopDAOTests.swift`
- `EchoTests/ArticleWorkshop/ArticleWorkshopFileStoreTests.swift`

## Conflict and failure-injection evidence

- A stale expected revision returns a typed conflict, rolls back the inserted sibling, preserves the concurrent revision, and leaves the capture pointer unchanged.
- A successful conditional publication inserts the immutable child and advances the capture pointer in the same transaction.
- Parent/base revisions must belong to the exact capture; missing captures and foreign parents fail closed.
- A save conflict preserves the unsaved recipe, dirty state, preview, and visible conflict state across later local edits.
- Malformed current-revision JSON, inconsistent metadata JSON, invalid recipes, and a current revision belonging to another capture fail closed.
- Snapshot loading ignores database `packagePath`, derives only `<root>/Captures/<capture UUID>/snapshot.json`, rejects symlinked ownership boundaries, enforces the existing byte bound, verifies the stored SHA-256, checks schema/capture identity, and sanitizes locally.

## Product and accessibility checks

- Cleanup is reachable only from the explicit **Clean Up Article** action; capture, Inbox reload, detail open, and anthology paths do not auto-clean.
- All original blocks remain present in source order. Removed blocks remain visible and restorable.
- Editing is limited to remove/restore, inclusive trim-above/trim-below, and metadata correction. There is no arbitrary prose replacement API, HTML editor, or `TextEditor`.
- Preview recomputation uses `ArticleRevisionService` after every accepted mutation.
- The UI uses native list, button, menu, context, and swipe actions, plus equivalent VoiceOver custom actions for remove/restore and both trim directions.
- Excluded, unsaved, and conflict states have text/icon labels rather than color-only meaning.
- Sections expose semantic headers, article text has no fixed line clamp, interactive controls have a 44-point minimum, and there is no custom animation requiring a Reduce Motion alternative.
- Leaving with unsaved cleanup requires confirmation.
- The conflict message is actionable and does not expose an internal revision UUID.

## Scope and dependency boundaries

- No change to `Echo.xcodeproj/project.pbxproj`, `ARCHITECTURE.md`, narration files, the share extension, or the Global Pronunciation sibling worktree.
- No Task 5/8 claim, Task 6 change, anthology builder, EPUB builder/export, narration/M4B work, network refetch, WebKit, image download, CloudKit operation, credential access, third-party dependency, or generalized editor abstraction.
- Verification here proves local compilation and the listed iOS Simulator tests only.
- Hosted CI, physical iPhone/iPad capture, Mac Safari capture, CloudKit cross-device behavior, external reader compatibility, EPUBCheck, M4B playback, human listening, merge, installation, and release remain separate unperformed gates.
- No iPhone Mirroring or physical-device control was used. Mac audio output was not used.

## Specification fix round 1

### Outcome

The cleanup view-model now validates and normalizes every accepted recipe at its boundary. Duplicate or out-of-order exclusions become known source IDs in exact immutable source order. The normalized recipe is used as the editor baseline, preview input, dirty-state comparison, mutation input, and later save value. Opening a stored revision does not publish or rewrite it; normalization persists only after an explicit save.

Unknown excluded or trim block IDs still fail closed through `ArticleRevisionService` before normalization. Trim bounds, metadata overrides, parent/current conflict handling, and readable-content hash behavior are unchanged.

### RED receipt

- `make build-tests`: passed with the new regression.
- `ArticleCleanupViewModelTests`: 10 tests executed; only `normalizesLoadedExclusionsBeforeMetadataOnlySave` failed. The loaded recipe and explicit metadata-only child save both retained `[b2, b0, b2]` instead of canonical `[b0, b2]`.
- An earlier simulator-host bootstrap exit executed zero tests and was not counted as a behavioral receipt.

### GREEN receipts

- `make build-tests`: `TEST BUILD SUCCEEDED`.
- `ArticleCleanupViewModelTests`: 10 tests passed.
- `ArticleRevisionServiceTests`: 5 tests passed.
- `ArticleWorkshopDAOTests`: 7 tests passed.
- `ArticleWorkshopFileStoreTests`: 8 tests passed.
- `ArticleInboxViewModelTests`: 9 tests passed.
- `ArticleInboxPresentationPolicyTests`: 2 tests passed.
- Total focused executable receipt for this round: 41 tests passed.
- Strict Swift formatting lint and `git diff --check`: passed.

The proof boundary remains local compilation and the listed iOS Simulator tests only. All external/device/release gates listed above remain unperformed.

## Quality fix round 2

### Outcome

Snapshot validation is now bound to one opened file identity. The store requires an initial non-symlink regular leaf, opens it once, reads through that handle, and compares regular-file device, inode, size, high-resolution modification time, and high-resolution change time before and after reading. It then uses non-following `lstat` metadata to require that the live path still names the same regular device/inode. The handle closes through `defer` on every post-open success or error path.

Cleanup rows now derive one deterministic presentation state from the immutable source and current recipe: included, explicitly removed, trimmed above, or trimmed below, with start/end boundary flags. SwiftUI displays non-color text/icon status and boundary labels while preserving every source row and structural action. The same state supplies a distinct VoiceOver value for included, removed, trimmed-above, trimmed-below, starts-here, and ends-here semantics.

Loading and saving now expose only stable user-safe messages. A local generation-owned coordinator cancels the prior logical load before retry, clears terminal state, loads the same capture, and rejects completion from stale generations. The loading failure surface includes a native **Try Again** action with a 44-point minimum. Typed revision conflicts retain their existing actionable copy; other save failures state that retry is available and unsaved choices remain.

### RED receipts

1. Deterministic validation hook: `make build-tests` failed because `ArticleWorkshopFileStore` had no `validationHook` argument. After the minimal Sendable post-read hook was added, the unchanged-file test and existing file-store suite passed.
2. File identity races: `ArticleWorkshopFileStoreTests` executed 11 tests. The unchanged-file test passed, while both `loadSnapshotRejectsAtomicSameLengthReplacementAfterRead` and `loadSnapshotRejectsSameInodeSameSizeRewriteAfterRead` failed because an error was expected but none was thrown; stale bytes were returned in both injected races.
3. Trim presentation: `make build-tests` failed because `ArticleCleanupBlockPresentation` and `ArticleCleanupViewModel.presentation(for:)` did not exist.
4. Safe errors and retry: `make build-tests` failed because `ArticleCleanupUserMessage` and `ArticleCleanupLoadingCoordinator` did not exist.

Compile corrections encountered during GREEN work were fixed before behavioral claims. Simulator bootstrap exits, a revision filter that executed zero Swift tests, and a run overlapping a sibling-owned simulator gate were not counted.

### GREEN receipts

- `make build-tests`: `TEST BUILD SUCCEEDED` on the exact committed source state.
- `ArticleCleanupViewModelTests`: 14 tests passed.
- `ArticleRevisionServiceTests`: 5 tests passed.
- `ArticleWorkshopFileStoreTests`: 11 tests passed.
- `ArticleWorkshopDAOTests`: 7 tests passed.
- `ArticleInboxViewModelTests`: 9 tests passed.
- `ArticleInboxPresentationPolicyTests`: 2 tests passed.
- Total focused executable receipt for this round: 48 tests passed.
- Strict Swift formatting lint passed for the Task 9-owned cleanup model, view, and model test.
- `git diff --check`: passed.

### Race, retry, privacy, and accessibility evidence

- Atomic equal-length replacement changes the live path identity after the read and throws `fileChangedDuringValidation`.
- Equal-length in-place rewrite preserves device/inode but changes descriptor modification/change metadata and throws `fileChangedDuringValidation`.
- An unchanged snapshot still loads successfully through the same descriptor-bound validation path.
- Exact workshop ancestry, byte bound, SHA-256, schema, capture ID, and sanitizer validation remain in force.
- A hostile load/save error containing a private filesystem path and `GRDB SELECT` text maps to fixed copy containing neither diagnostic. Capture-missing, invalid saved cleanup, original-capture failure, temporary load failure, conflict, and generic save categories have distinct stable messages.
- Failure followed by one retry starts exactly one new attempt and reaches the new result.
- A canceled earlier load resumed after the retry result cannot overwrite the current view model.
- The seven-row presentation fixture proves trimmed-above, starts-here boundary, included interior, explicit exclusion within retained bounds, ends-here boundary, and trimmed-below states in original source order.
- Visible labels and VoiceOver values share the tested presentation state; no prose replacement control, raw-path diagnostic, SQL diagnostic, color-only state, or custom animation was introduced.

The proof boundary remains local compilation, static review, and the listed iOS Simulator tests only. Hosted CI, physical-device capture, cross-device CloudKit behavior, external reader/EPUBCheck compatibility, M4B playback, human listening, merge, installation, and release remain unperformed.
