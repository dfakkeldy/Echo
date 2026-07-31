# Task 10 report: anthology projects, stable slots, manifests, and builder UI

Date: 2026-07-29

## Outcome

Task 10 is locally implemented. Echo can now create reusable anthology projects
from eligible Article Inbox captures, edit project and chapter metadata, assign
per-entry voices, reorder and remove entries without reusing stable slots, choose
and safely copy an immutable managed cover, run structural cleanup in context,
and explicitly prepare an immutable build manifest. This task does not create an
EPUB, synthesize narration, or export M4B.

The implementation keeps the Task 10 boundary local: manifest preparation reads
only durable managed snapshots and the database, performs no network or WebKit
work, sends no CloudKit data, and handles no browser credentials.

## Files

Shared models and revision materialization:

- `Shared/ArticleWorkshop/AnthologyBuildManifest.swift`
- `Shared/ArticleWorkshop/ArticleRevisionMaterializer.swift`
- `Shared/ArticleWorkshop/LibraryMode.swift`

Persistence:

- `Shared/Database/DAOs/AnthologyDAO.swift`
- `Shared/Database/DAOs/ArticleCaptureDAO.swift`
- `Shared/Database/Migrations/Schema_V37.swift`
- `Shared/Database/DatabaseService.swift`

Services, view models, and views:

- `EchoCore/Services/ArticleWorkshop/AnthologyService.swift`
- `EchoCore/Services/ArticleWorkshop/AnthologyCoverStore.swift`
- `EchoCore/Services/ArticleWorkshop/ArticleInboxService.swift`
- `EchoCore/ViewModels/AnthologyBuilderViewModel.swift`
- `EchoCore/ViewModels/AnthologyListViewModel.swift`
- `EchoCore/ViewModels/ArticleInboxViewModel.swift`
- `EchoCore/ViewModels/ArticleCleanupViewModel.swift`
- `EchoCore/Views/ArticleWorkshop/AnthologyListView.swift`
- `EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift`
- `EchoCore/Views/ArticleWorkshop/AnthologyBuilderView.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift`
- `EchoCore/Views/Library/LibraryView.swift`

Tests:

- `EchoTests/ArticleWorkshop/AnthologyServiceTests.swift`
- `EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift`
- `EchoTests/ArticleWorkshop/AnthologyCoverStoreTests.swift`
- `EchoTests/ArticleWorkshop/ArticleWorkshopDAOTests.swift`
- `EchoTests/ArticleWorkshop/SchemaV37ArticleWorkshopTests.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxServiceTests.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxViewModelTests.swift`
- `EchoTests/ArticleWorkshop/ArticleCleanupViewModelTests.swift`

The protected shared narration/project files, `ARCHITECTURE.md`, share extension,
and sibling Global Pronunciation worktree were not modified.

## RED receipts

Tests were added before each behavior and observed failing for the intended
reason. Representative retained logs include:

- `/tmp/task10-atomic-red.log`: atomic multi-add and stable-slot expectations
  failed against the initial single-entry implementation (12 tests, 3 issues).
- `/tmp/task10-cover-red.log`: same-format cover replacement overwrote
  `cover.png`, so immutable prior-cover and Changes Available expectations failed
  (27 tests, 4 issues).
- `/tmp/task10-list-red.log`: an older list reload overwrote newer state and the
  list/builder accessibility presentation contracts were absent (16 tests, 4
  issues).
- `/tmp/task10-inbox-red.log`: missing/failed packages could seed anthologies and
  failed rows could enter selection (28 tests, 5 issues).
- `/tmp/task10-review-red-build.log`: the list model lacked the safe
  `dismissMessage` recovery surface; the test target did not compile.
- Additional retained RED logs cover stale membership, queued-draft rebasing,
  compound persistence/build failure, schema uniqueness repair, canonical cover
  ownership, and malformed prior-manifest validation.

## GREEN receipts

Exact formatted-state verification:

- `make build-tests`
  - Result: `** TEST BUILD SUCCEEDED **`
  - Log: `/tmp/task10-final-build.log`
- Focused Task 10 matrix using `xcodebuild test-without-building`
  - 115 tests passed across 9 suites
  - Result: `** TEST EXECUTE SUCCEEDED **`
  - Log: `/tmp/task10-focused-final.log`
  - Suites: anthology service, builder/list models, cover store, DAO, v37
    migration, cleanup model, inbox service/model, and managed file store.
- Remaining Article Workshop regression/security matrix using
  `xcodebuild test-without-building`
  - 63 tests passed across 8 suites
  - Result: `** TEST EXECUTE SUCCEEDED **`
  - Log: `/tmp/task10-article-workshop-wider.log`
  - Suites: capture envelope, block sanitizer, inbox presentation policy,
    revision service, WebKit extraction policy, URL capture, image downloader,
    and inbox ingestion.
- Combined executable Task 10/Article Workshop evidence:
  - 178 tests passed across 17 suites.
- `swift format lint --configuration .swift-format <all changed Swift files>`
  - Passed with no diagnostics.
- `git diff --check`
  - Passed with no diagnostics.

Repository-wide lane:

- `make test` is **unavailable, not passing**.
- Xcode executed 0 tests. The generated xcresult records one harness failure:
  the Echo test process was killed while preparing to run, before bootstrap
  completed.
- This is kept separate from the 178 executable passing tests and is not
  interpreted as a green repository-wide result.

## Persistence, concurrency, and failure evidence

- Project creation and multi-entry addition are atomic.
- Display order is always dense, while `stableSlot` is monotonic and never
  reused after removal.
- Draft saving uses an optimistic persisted-membership token. A stale editor
  cannot delete an entry added concurrently.
- Queued local edits rebase only after their preceding save is durably
  acknowledged.
- A successful save is acknowledged before a later prepare/add/reload step, so a
  downstream failure does not make Retry submit a stale membership token.
- Project metadata updates do not regress DAO-managed counters.
- Build receipts are insert-only; only successful edition revisions are unique,
  and the additive v37 repair removes the former failed-attempt uniqueness.
- Baseline cleanup revision publication is conditional. A concurrent real
  cleanup wins and is reloaded before manifest materialization.
- One GRDB read snapshot supplies project, entries, captures, current revisions,
  and latest successful build evidence.
- Prior manifests and build records are decoded and validated as immutable
  evidence; they are never rewritten to clear Changes Available.
- Failed immediate saves keep the visible draft, show Not Saved plus a safe
  retry action, and do not simultaneously claim Saved.

## Manifest and security evidence

- Frozen manifests include exact capture/revision IDs, stable slots, dense
  display order, clean blocks, readable hashes, source metadata, and entry voice
  overrides.
- Stored revision ownership, canonical recipe/metadata agreement, immutable
  snapshot application, and recomputed readable digest are validated through
  the shared materializer.
- Malformed IDs, dates, URLs, JSON, hashes, ownership, ordering, package state,
  and prior-manifest semantics fail closed with user-safe errors.
- Source URLs must be absolute HTTP(S) and cannot contain user/password
  credentials.
- Failed capture records and durable snapshots whose content state is failed are
  ineligible for anthology membership.
- Inbox seeding delegates to full anthology eligibility validation and leaves
  both project and membership tables empty on failure.
- User cover imports reject symlinks, malformed/non-image data, oversized bytes,
  dimensions, and pixel counts. Accepted covers are content-addressed,
  atomically copied into the matching managed anthology directory, and
  immutable across replacements.
- The changed-source privacy scan found no new networking, CloudKit,
  `UserDefaults`, secret storage, or developer-machine path in production code.
  Matches were the production URL credential rejection plus explicit hostile
  URL/private-path test fixtures.

## Accessibility and user-visible behavior

- Native list/form/navigation controls retain Dynamic Type behavior.
- Reordering has drag parity through named Move Up and Move Down accessibility
  actions.
- Table-of-contents rows expose stable-slot labels independent of display order.
- Add Articles, Clean Up, cover choice, and Build remain named reachable actions.
- Selection excludes failed Inbox rows.
- Saved, Not Saved, Changes Available, and prepared revision are textually
  distinct and do not rely on color.
- The cover surface says `Using Chosen Image` and does not expose a hash-derived
  filename to the user.
- Books and Inbox toolbar behavior remains isolated by library mode.

## Independent review

Specification and implementation reviewers inspected the live worktree during
implementation. Confirmed findings were fixed, including:

- stale membership overwriting concurrent additions;
- queued-edit membership rebasing and compound-step retry correctness;
- mutable same-name cover replacement;
- cover ownership and symlink boundaries;
- list reload last-request-wins behavior;
- failed Inbox selection and invalid anthology seeding;
- failed build receipt uniqueness;
- current-revision and durable content-state validation;
- Saved/error state contradiction;
- semantic validation of frozen prior manifests.

Both reviewers reported no remaining confirmed Important finding before the
final commit. Their final immutable-SHA verdict is requested after commit.

## Proof boundaries

- Local implementation: complete.
- Swift formatting: passed.
- Test-target build: passed.
- Focused simulator tests: 178 passed across 17 suites.
- Repository-wide all-EchoTests simulator lane: unavailable due pre-bootstrap
  SIGKILL; 0 tests executed.
- Hosted CI: not run by this task.
- Physical iPhone/iPad capture and acceptance: pending; device explicitly
  unavailable.
- iPhone Mirroring: not attempted; GeoPDF retains ownership.
- CloudKit cross-device proof: pending and outside Task 10.
- EPUB generation and EPUBCheck: pending Task 11/12; no EPUB produced here.
- External reader compatibility: pending after EPUB export exists.
- Stable edition import: pending Task 13.
- Narration integration: pending shared narration dependency and Task 14.
- M4B export/playback: pending Task 15; no playback probe performed.
- Human listening: pending; Mac output remained muted.
- Merge, installation, and release: pending parent integration and repository
  workflow.
