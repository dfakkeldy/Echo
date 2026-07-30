# Task 7 Report: Article Inbox and Library Mode Selector

Date: 2026-07-29  
Base: `daf7e4ea263ca792d985644bd2da8decf28e2d86`

## RED receipts

- The initial `make test-only FILTER=EchoTests/ArticleInboxServiceTests` used a stale
  test bundle and reported zero executed tests. It was rejected as behavioral
  evidence.
- A fresh `make build-tests` then exited through `make` with status 2
  (`xcodebuild` status 65). Both planned test suites were included in compilation
  and failed because `ArticleInboxService` and `ArticleInboxViewModel` did not
  exist. This was the valid executable RED receipt.

## Implementation summary

- Added shared Library mode, Inbox presentation-state, item, and deletion-impact
  models.
- Added an Inbox service that sorts captures deterministically, decodes warnings
  defensively, presents unknown states as failed, flags possible duplicates
  without merging or deleting, creates minimal anthology seeds in visible Inbox
  order, and reports every referencing anthology before deletion.
- Added exact-owned-path capture deletion with regular-directory and symlink
  checks plus a quarantine/restore flow around database deletion.
- Added a MainActor observable Inbox view model that drains complete staging
  packages before fetching, preserves the last successful list on error, prunes
  stale selection, supports predictable select-all behavior, and creates minimal
  anthology seeds.
- Mounted Books, Inbox, and Anthologies below the existing iOS Library title.
  Existing shelf content and toolbar actions remain Books-only. Inbox includes
  loading and empty states, explicit ready/review/failed labels, duplicate
  warning and Keep Both copy, multi-selection, New Anthology, cleanup-on-demand
  navigation, and deletion confirmation. Anthologies shows only current records
  or a bounded placeholder; it does not implement the Task 10 builder.
- Article detail exposes only valid HTTP or HTTPS original links and does not
  mutate article prose. Task 9 continues to own structural editing.

## GREEN receipts

- `make build-tests`: `** TEST BUILD SUCCEEDED **` after all final source changes.
- `make test-only FILTER=EchoTests/ArticleInboxServiceTests`: 8 tests in 1 suite,
  all passed; `** TEST EXECUTE SUCCEEDED **`.
- `make test-only FILTER=EchoTests/ArticleInboxViewModelTests`: 4 tests in 1
  suite, all passed; `** TEST EXECUTE SUCCEEDED **`.
- `make test-only FILTER=EchoTests/LibraryViewModelTests`: 13 tests in 1 suite,
  all passed; `** TEST EXECUTE SUCCEEDED **`.
- `xcrun swift-format lint --strict --configuration .swift-format ...`: passed
  for every Task 7 Swift file.
- `git diff --check`: passed.

## Security checks

- A record-supplied path must exactly equal
  `<fileStore.root>/Captures/<capture UUID>` after standardization.
- The owned root, `Captures` directory, and capture package must each be regular,
  non-symlink directories.
- Forged out-of-root and symlinked-package tests prove arbitrary files and the
  database row remain untouched on refusal.
- Referenced deletion returns sorted, unique anthology names and refuses all
  file/database mutation.
- Unreferenced deletion moves only the exact owned package to a narrowly scoped
  quarantine, restores it if database deletion fails, and deletes it only after
  the row is removed.
- Duplicate URL/digest evidence is warning-only and never authorizes merge or
  deletion.
- The detail UI launches only well-formed HTTP or HTTPS original URLs.
- Inbox reload and detail presentation perform no network, image-download, or
  CloudKit work.

## Accessibility checks

- Uses native segmented Picker, List, NavigationLink, Button, Link, alert, and
  confirmation-dialog semantics.
- Selection and cleanup controls have a 44-point minimum target; toolbar and
  picker controls use native hit targets.
- Ready, review, failed, possible-duplicate, and cleanup-on-demand states use
  visible text and symbols, not color alone.
- VoiceOver selection labels say Select or Deselect according to the pending
  action and expose Selected or Not selected as the value.
- Headings, original-link hints, cleanup hints, and anthology labels have
  explicit semantics.
- Text uses semantic fonts and unbounded wrapping for Dynamic Type.
- No custom motion or animation was introduced, so Reduce Motion requires no
  alternate path.

## Exact changed files

- `Shared/ArticleWorkshop/LibraryMode.swift`
- `EchoCore/Services/ArticleWorkshop/ArticleInboxService.swift`
- `EchoCore/ViewModels/ArticleInboxViewModel.swift`
- `EchoCore/Views/ArticleWorkshop/LibraryModePicker.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift`
- `EchoCore/Views/ArticleWorkshop/ArticleDetailView.swift`
- `EchoCore/Views/Library/LibraryView.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxServiceTests.swift`
- `EchoTests/ArticleWorkshop/ArticleInboxViewModelTests.swift`

## Remaining proof boundaries

- Local implementation, simulator compilation, and the three focused simulator
  suites are complete.
- No physical iPhone/iPad capture, Safari extension acceptance, iPhone
  Mirroring, CloudKit cross-device proof, external reader compatibility, EPUB
  export, M4B playback, Mac parity, or human listening was performed.
- Hosted CI, review acceptance, merge to `nightly`, installation, TestFlight,
  deployment, and release remain separate pending states.
- Task 5 remains dependency-blocked. Task 6 classifier acceptance is not claimed.
- Task 9 structural editing and Task 10 full anthology building remain outside
  this commit.

## Specification fix round 1

### RED

- Added `matchingStoredSourceURLIsDuplicateEvidence` before production changes.
  Its two real database records shared one exact stored source URL, while one
  canonical URL was absent, the other was different, and both content digests
  differed.
- A fresh `make build-tests` succeeded and included the new test.
- `make test-only FILTER=EchoTests/ArticleInboxServiceTests` then executed 9
  tests and failed only the new regression: observed possible-duplicate flags
  were `[false, false]`, expected `[true, true]`. The command ended with
  `** TEST EXECUTE FAILED **`, `xcodebuild` status 65, and `make` status 2.

### Fix

- Added exact stored `sourceURL` equality to the existing duplicate-evidence
  predicate after self-exclusion by capture ID.
- Preserved canonical URL and nonempty digest evidence, deterministic Inbox
  ordering, nonblocking Keep Both behavior, and both database rows.
- Added no URL normalization, canonicalization, refetch, merge, deletion,
  schema, DAO, UI, share-extension, classifier, narration, project, or
  architecture change.

### GREEN

- `make build-tests`: `** TEST BUILD SUCCEEDED **`.
- `make test-only FILTER=EchoTests/ArticleInboxServiceTests`: 9 tests in 1
  suite passed; `** TEST EXECUTE SUCCEEDED **`.
- `make test-only FILTER=EchoTests/ArticleInboxViewModelTests`: 4 tests in 1
  suite passed; `** TEST EXECUTE SUCCEEDED **`.
- `make test-only FILTER=EchoTests/LibraryViewModelTests`: 13 tests in 1 suite
  passed; `** TEST EXECUTE SUCCEEDED **`.
- Strict swift-format lint passed for both changed Swift files.
- `git diff --check` passed.

## Quality fix round 2

### RED receipts

- Atomic anthology creation: after adding real database assertions, the focused
  service suite executed 10 tests and failed because the returned and stored
  `nextStableSlot` remained `0` instead of `2`; a duplicate third capture then
  failed a real unique constraint after leaving the anthology and earlier
  entries committed.
- Background reload: a fresh test build failed only because the wished-for
  `ArticleInboxReloadWorker`, `ArticleInboxReloadResult`, and worker initializer
  did not exist. The deterministic test blocks the worker on a semaphore and
  requires another MainActor job to complete before release.
- Deletion commit point: a fresh test build failed only because
  `ArticleInboxService.DeletionPoint` and the narrow `deletionHook` initializer
  seam did not exist. Tests inject failures immediately before database commit
  and immediately before quarantine cleanup, plus a late anthology reference.
- Presentation policies: a fresh test build failed because
  `LibraryModePickerPolicy` and `warningOccurrences` did not exist.

### Fix

- Added one `AnthologyDAO.create` write transaction that validates every capture,
  inserts ordered entries with deterministic sort orders and stable slots, and
  commits `nextStableSlot` only with the complete seed. Existing managed-counter
  `save` behavior is unchanged.
- Added one bounded Sendable reload worker. Production staging enumeration,
  import, cleanup, Inbox fetch, and anthology fetch run in an awaited detached
  task; the MainActor view model only publishes importing state and one complete
  result.
- Made the database deletion the logical commit point. Precommit failures restore
  the exact owned package; the DAO rechecks references and deletes in one write
  transaction. Postcommit cleanup failures return success and retain a canonical
  quarantine for later safe reconciliation.
- Reconciliation validates the entire quarantine set before removing anything:
  direct-child canonical `<capture UUID>-<nonce UUID>` names, regular
  non-symlink directories, and absent capture rows are all required.
  Unrecognized residue fails closed and remains untouched.
- After logical deletion, the view model removes the article and selection before
  reload. A later reload failure preserves that accurate list and publishes the
  error.
- Warning occurrences now use stable per-index identity while preserving warning
  text. The Library picker remains segmented at standard Dynamic Type sizes and
  uses a native labeled menu with the same three modes at accessibility sizes.

### Failure-injection GREEN receipts

- `ArticleInboxServiceTests`: 14 tests passed. This includes full anthology
  rollback, precommit package/row restoration, logical success with postcommit
  residue, later safe reconciliation, late-reference refusal and restoration,
  and fail-closed preservation of unrecognized residue.
- `ArticleInboxViewModelTests`: 6 tests passed. The blocked worker yielded to a
  MainActor heartbeat, and a failed reload after logical deletion did not
  resurrect the article or selection.
- `ArticleInboxPresentationPolicyTests`: 2 tests passed. Both Dynamic Type
  branches expose Books, Inbox, and Anthologies, and identical warning strings
  retain distinct occurrence identities.

### Final GREEN receipts

- `make build-tests`: `** TEST BUILD SUCCEEDED **` after the final adversarial
  regression was added.
- `make test-only FILTER=EchoTests/ArticleInboxServiceTests`: 14 tests passed.
- `make test-only FILTER=EchoTests/ArticleInboxViewModelTests`: 6 tests passed.
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`: 16 tests
  passed.
- `make test-only FILTER=EchoTests/ArticleWorkshopDAOTests`: 5 tests passed.
- `make test-only FILTER=EchoTests/LibraryViewModelTests`: 13 tests passed.
- `make test-only FILTER=EchoTests/ArticleInboxPresentationPolicyTests`: 2 tests
  passed.
- Strict `swift-format` lint passed for all 11 changed Swift files.
- `git diff --check` passed.

### Proof boundaries

- Local implementation, simulator compilation, and focused iPhone 17 simulator
  suites are complete.
- No physical-device capture, iPhone Mirroring, CloudKit cross-device proof,
  external reader compatibility, EPUBCheck/export, M4B playback, Mac Safari
  capture, or human listening was performed.
- Hosted CI, review acceptance, merge, installation, TestFlight, deployment, and
  release remain separate pending states.
## Quality fix round 3

### RED

- Added deterministic overlapping-reload coverage before changing production code. `ArticleInboxViewModelTests` executed 9 tests and the three new regressions failed with 6 issues: an older reload published stale content, an older reload resurrected a logically deleted article, and a cancelled older reload published its result; each older reload also cleared the newer reload's importing state.
- Added owned-root and bounded-quarantine coverage before changing production behavior. The initial build correctly failed because the explicit deletion-quarantine limit seam did not exist. After adding only the inert seam, `ArticleInboxServiceTests` executed 17 tests: the symlinked workshop root was accepted and removed the target quarantine, while an over-limit quarantine reconciled all three entries instead of failing before mutation. The at-limit case and the existing unrecognized-entry case remained green.
- One symlink test invocation exited before test bootstrap and one method filter matched zero tests. Neither is counted as behavioral evidence; the subsequent full-suite executions are the accepted RED receipts.

### Fix

- Replaced detached reload work with a structured, awaited actor worker and added a monotonically increasing reload generation. Only the latest generation may publish results or errors, prune selection, or clear the importing state. Logical deletion invalidates in-flight reloads before it updates the visible list. Cancellation is checked by the worker and at staging/fetch boundaries.
- Required the workshop root and deletion-quarantine root to be exact regular, non-symlink directories before reconciliation. Direct children are enumerated without recursion and collected only through the configured limit plus one. The production limit is 128, tests can provide a smaller limit, and an over-limit or enumeration failure is reported before any residue is removed.

### GREEN

- `ArticleInboxViewModelTests`: 9/9 passed, including overlapping latest-wins publication, old-result-after-deletion suppression, and cancellation isolation.
- `ArticleInboxServiceTests`: 17/17 passed, including symlinked workshop-root rejection, over-limit no-mutation behavior, at-limit reconciliation, and existing unrecognized-residue rejection.
- `ArticleInboxIngestionServiceTests`: 16/16 passed.
- `ArticleWorkshopDAOTests`: 5/5 passed.
- `LibraryViewModelTests`: 13/13 passed.
- `ArticleInboxPresentationPolicyTests`: 2/2 passed.
- `make build-tests`: `** TEST BUILD SUCCEEDED **`.
- Strict Swift formatting lint and `git diff --check` passed for the five changed source/test files.
- No project, narration, architecture, or other shared-dependency files changed.

### Proof boundaries

- These receipts establish local compilation and iPhone 17 simulator behavior only. Hosted CI, physical-device capture, CloudKit cross-device proof, external-reader compatibility, M4B playback, human listening, merge, installation, and release remain separate pending gates.
