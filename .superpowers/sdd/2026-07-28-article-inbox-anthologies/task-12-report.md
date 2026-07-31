# Task 12 Report — Atomic EPUB publication and Echo library import

## Scope and frozen base

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Branch: `codex/article-anthology-design`
- Frozen base: `387130c7274643b05288bf8f1b6ac22a93343828`
- Added the Task 12 build service and its two focused test suites; modified anthology detail.
- With parent coordination approval, made the minimum demonstrated runtime plumbing changes in
  `LibraryView.swift` and `AnthologyListView.swift` so detail receives the existing
  `DatabaseService`-backed build service and existing `openBook` closure. No global or singleton
  database/navigation path was added.
- Fix round 1 made small default-preserving API changes to `EPUBImportCoordinator`,
  `EPUBAutoImportScanner`, and `DocumentImportFinalizer` so Task 12 can explicitly forbid
  ubiquitous-item and CloudKit fetches. Ordinary import callers retain the existing standard
  network policy by default.
- Did not change protected narration files, the Xcode project, `ARCHITECTURE.md`, Task 13 identity,
  CloudKit, M4B, sibling worktrees, or physical devices.

## TDD evidence

- Initial service RED: the focused test build failed because `AnthologyBuildService` did not exist.
- Actor-isolation RED: the first service draft failed strict-concurrency compilation before
  database-writer capture was corrected.
- UI-state RED: tests failed to compile before the separate EPUB presentation policy, overlap
  guard, and load/build generation tokens existed.
- Persisted-status RED: tests failed to compile because the service had no validated persisted
  snapshot operation.
- Adversarial matrix RED: the prior-shelf-load case demonstrated a confirmed preservation defect.
  A swallowed load error was incorrectly treated as “no previous audiobook” and could replace
  prior shelf metadata. The service now records failure and stops before publication when prior
  library state cannot be read.
- Review-fix RED: a real-coordinator rebuild/late-failure integration exposed that the coordinator
  deleted the `.epub` rollback backup; the new offline integration also failed to compile before an
  explicit network policy and request observer existed.
- Review-fix round 2 RED: the publication transaction initially returned no rollback token when its
  directory sync failed after replacement. The new injected first-publication, replacement, and
  forced recovery-fallback cases failed before publication owned compensation for that state.
- Semantic-restore RED: the first full-row comparison found that repeat import may serialize marker
  JSON object keys in a different order. Evidence now canonicalizes JSON object key order and
  compares every persisted semantic block field while excluding import timestamps.
- Review-fix round 3 RED: exact-SHA review confirmed that all three compensation paths swallowed a
  recovery directory-sync failure, so a durability failure could be reported as the original build
  error. Recovery-sync fault injection and distinct failure status did not exist at that SHA.
- Final Task 12 service suite: 18 declared tests passed. Its two parameterized tests exercised eleven
  build failure points and six receipt/identity mismatches; counting parameter expansions,
  the suite covered 33 cases.
- Final real integration suite: 2/2 passed through the real Task 11 builder/preflight and
  `EPUBImportCoordinator`. The late-failure test performs initial, candidate, and restored-prior
  imports; the observed block counts are seven, six, and seven respectively, with one TOC entry per
  import.

## Implemented behavior

- `AnthologyBuildService` is actor-isolated and rejects a second same-anthology build before its
  builder can run.
- Each attempt freezes one immutable `AnthologyBuildManifest`, canonicalizes it, and records its
  SHA-256.
- The builder receives only the frozen manifest and an exact managed direct-child
  `.book-<UUID>.epub` destination. The Task 12 service contains no network-fetch path.
- Task 11 preflight is required, followed by an independent `O_NOFOLLOW` regular-file/digest check
  before publication.
- Publication uses `ArticleWorkshop/Editions/<anthology UUID>/book.epub`. A rebuild swaps the
  previous regular file into an exact owned direct-child `.book-<UUID>.rollback` backup. The
  non-EPUB extension prevents normal companion cleanup from deleting rollback state.
- Publication owns post-rename durability failures before returning a rollback token. A failed
  first publication removes its candidate; a failed replacement sync restores the prior file by
  swap, then by a two-rename fallback if the recovery swap itself fails. A compensation failure is
  reported distinctly as `publication_recovery_failed` instead of claiming preservation. Recovery
  directory sync is required and never swallowed in the first-publication, reverse-swap, or
  two-rename path.
- The Books shelf row uses one stable explicit identity: the standardized edition-directory URL.
  Rebuilds update the same row with anthology title, creator, managed cover path, availability, and
  EPUB text origin.
- The real import coordinator consumes the final URL and explicit stable identity. Task 12 checks
  the returned identity and final digest before saving the successful receipt/latest-success
  revision.
- Task 12 invokes the real coordinator with `.localOnly`. The policy is propagated through fresh
  import and already-imported finalization, permits already-materialized local sidecars, treats
  dataless placeholders as pending, and skips ubiquitous downloads and CloudKit anchor lookup.
- Persisted UI state independently revalidates canonical manifest evidence, exact edition/final
  path, EPUB digest, stable audiobook identity, availability, and EPUB text origin before enabling
  output actions.
- EPUB status is independent: not built, building, ready, changes available, or failed with an
  optional previous revision. Build/Rebuild, Open in Echo, and Share EPUB are gated separately.
- Open targets the stable edition directory; Share targets `book.epub`. Open/Share are disabled
  during build because the backup/restore protocol temporarily occupies the final path with the
  candidate.
- Build/Rebuild is disabled while a save is active or a failed autosave awaits retry, so the service
  cannot freeze older database state behind visible unsaved edits.
- Fixed safe errors provide retry and dismiss. Generation tokens suppress stale overlapping
  load/build presentation, including a second token check after the failure snapshot actor hop.
  Labels do not rely on color, controls have 44-point minimum height, and `ViewThatFits` stacks
  actions vertically when horizontal space or Dynamic Type requires it.
- Switching back to Books mode reloads the library model so the newly imported normal shelf row is
  visible without waiting for a later view appearance.

## Failure and security matrix

Every injected primary failure below records a failed attempt at the same revision while preserving
the previous successful EPUB bytes, latest-success receipt/pointer, and usable shelf row:

1. builder failure before output;
2. Task 11 preflight failure;
3. prior library-state load failure;
4. replacement publication failure after rename and before directory sync, using swap recovery;
5. the same failure with the recovery swap forced to fail, using the two-rename fallback;
6. reverse-swap recovery directory-sync failure;
7. two-rename fallback recovery directory-sync failure;
8. shelf-row save failure after publication;
9. importer failure after publication;
10. post-import final-digest mutation;
11. successful-receipt save failure.

Additional fail-closed coverage:

- first-publication failure after rename and before directory sync removes the candidate, records
  failure, and leaves no successful receipt, shelf row, final EPUB, or Task 12 residue;
- first-publication reversal directory-sync failure preserves that live cleanup state while
  returning `publicationRecoveryFailed` and recording `publication_recovery_failed`;
- temporary URL, manifest digest, EPUB digest, identifier, revision, and imported audiobook identity
  mismatches;
- staged-file symlink, symlinked final destination, and substituted result path without external
  writes;
- regular Task 12 temporary/backup residue removal after success and the eleven normal failure
  points;
- exact direct-child, non-EPUB rollback naming while an import is pending;
- exact digest checks before and after import;
- stable audiobook identity across rebuilds;
- failed retry reuses the unconsumed revision;
- source scan for network APIs and literal network endpoints;
- explicit `.localOnly` production policy at both initial and restoration imports;
- real-coordinator zero-request observation with a dataless iCloud sidecar placeholder;
- real-coordinator late successful-receipt failure restoring prior EPUB bytes, success
  receipt/latest pointer, shelf metadata, blocks/TOC, and leaving zero task residue;
- Task 11 `missingImageAssetMapping` records `missing_image_asset_mapping`, preserves the previous
  edition, and does not silently omit or refetch the image.

Task 11’s upstream managed article-image descriptor dependency remains explicit. Task 12 does not
broaden that schema/capture boundary.

## Verification

- `make build-tests`: passed after final formatting.
- Combined affected simulator run: 118 declared tests passed in 10 suites:
  `AnthologyBuildServiceTests`, `AnthologyLibraryIntegrationTests`, `AnthologyServiceTests`,
  `AnthologyBuilderViewModelTests`, `AnthologyEPUBBuilderTests`,
  `AnthologyEPUBPreflightTests`, `EPUBImportCoordinatorTests`,
  `EPUBAutoImportScannerTests`, `DocumentImportFinalizerTests`, and
  `ArticleWorkshopDAOTests`.
- Real integration: initial success and late-failure restoration passed; stable identity, title,
  creator, managed cover, text origin, prior EPUB bytes, every prior semantic block field,
  prior TOC, and zero network request observations were verified. Marker/text-format JSON is
  compared canonically because object-key order is not semantic.
- Strict `swift-format` lint on all changed Swift implementation/test files: passed.
- `git diff --check`: passed.
- Privacy/network scan: no Task 12 production network API, literal endpoint, credential, token,
  secret, or user-specific path.
- Protected-file diff: empty.

## Review

- Implementer self-review: complete. It confirmed and fixed the swallowed prior-library-load error,
  disabled Open/Share during the transient candidate-import window, and closed offline-policy
  propagation through the already-imported scanner branch.
- Initial exact-SHA specification review of
  `b036eeecbf7068db24de5a99fa7d9eaa0f928942`: FAIL. It confirmed that the real coordinator
  deleted the `.epub` rollback backup, that real prior-import rollback coverage was absent, and that
  Task 12 lacked an explicit transitive no-network mode.
- Initial exact-SHA adversarial implementation review of
  `b036eeecbf7068db24de5a99fa7d9eaa0f928942`: FAIL. It independently confirmed rollback deletion,
  plus Build EPUB after failed autosave and a missing post-await stale-result check.
- Implementer fix round 1: all confirmed findings were fixed and covered by focused real-coordinator,
  policy, UI-state, and generic importer/finalizer regressions. The Books-mode reload VERIFY item was
  also confirmed from code and fixed.
- Exact-SHA specification re-review of
  `5ca766eb183c852f63a0b92719491fd4d9b7cf42`: PASS, with no confirmed issues.
- Exact-SHA adversarial implementation re-review of
  `5ca766eb183c852f63a0b92719491fd4d9b7cf42`: FAIL. It confirmed that a throwing directory sync
  after rename could leave an unowned publication state, and that the report overstated the
  candidate import’s block count and lacked exact restored-block comparisons.
- Implementer fix round 2: publication now compensates before returning its token; injected tests
  cover first publication, replacement swap recovery, and forced fallback recovery. The real
  integration compares every restored semantic block field and accurately reports 7/6/7 blocks.
- Exact-SHA round-2 specification re-review of
  `7b2f44f06c7c3e66c531953169694ca941e5b65b`: PASS, with no confirmed issues.
- Exact-SHA round-2 adversarial implementation re-review of
  `7b2f44f06c7c3e66c531953169694ca941e5b65b`: FAIL. It confirmed that recovery directory-sync
  failures were swallowed after first-publication reversal, reverse-swap recovery, and fallback
  recovery. The reviewer’s focused test host failed before bootstrap twice; that unavailable probe
  was not counted as a test result.
- Implementer fix round 3: all three recovery paths now require their directory sync and translate
  its failure to `publicationRecoveryFailed`; injected tests assert the matching persisted
  `publication_recovery_failed`, prior/absent-first live state, shelf/receipt preservation, and zero
  Task 12 residue.
- Exact-SHA round-3 specification re-review of
  `0ccfaec26566df2187bd034d1385cac553908a67`: PASS, with no confirmed issues.
- Exact-SHA round-3 adversarial implementation re-review of
  `0ccfaec26566df2187bd034d1385cac553908a67`: PASS, with no confirmed issues. Its fresh
  build-for-testing, 18-test service suite, 2-test real integration, format, diff, and protected-file
  checks passed.
- VERIFY-only hardening remains separate from Task 12 acceptance: partial failure of the second
  fallback rename, directory-entry TOCTOU hardening beyond pathname APIs, and crash/late-cleanup
  recovery. None was reinterpreted as passed.

## Proof status

- Local Task 12 implementation, format, security scans, simulator build, focused tests, real
  importer integration, and affected regressions: passed as listed above.
- Task 11 article-image builds: waiting for the upstream managed asset descriptor contract; the
  fail-closed preservation path is passed.
- Hosted CI: not run.
- Physical iPhone/iPad capture and acceptance: pending; the user reported the device unavailable
  and it was not requested or accessed.
- CloudKit cross-device proof: pending and outside Task 12.
- External-reader compatibility and EPUBCheck: pending; not reinterpreted as passing.
- M4B generation/playback: not part of Task 12 and remains pending for later tasks.
- Mac or physical-device playback and human listening: pending; no playback probe was run.
- Merge, installation, and release: pending.
