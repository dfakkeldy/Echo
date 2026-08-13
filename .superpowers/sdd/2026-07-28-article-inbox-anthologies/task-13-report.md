# Task 13 report — stable generated block identity and reconcile import

Date: 2026-07-29

## Outcome

Task 13 is locally implemented. Echo-generated anthologies now retain stable
block identity across chapter reorder and rebuild, while ordinary external EPUBs
remain order-based and use the existing replace-all import policy. Only the
anthology build service can construct the trusted in-memory identity capability
needed to request generated reconciliation.

Task 12 late-failure recovery now re-imports the prior edition with its prior
validated manifest identity and restores a bounded exact database snapshot. A
failure before generated import commits restores only the prior shelf metadata;
it does not misclassify untouched article rows as a failed library recovery.

## Persistence and identity

- V38 adds nullable `epub_block.source_chapter_key` after V37.
- A real V37-to-V38 migration preserves existing generic IDs and user fields.
- Fresh schema creation has the same nullable column.
- Generated IDs use
  `epub-<audiobookID>-s<stableSlot>-b<stableBlockIndex>`.
- Trusted validation requires the exact package identifier and manifest digest,
  a unique expected chapter href and stable slot, exact reserved/body indices,
  exact kind/text/class/tag/code/narration/source semantics, and one complete
  expected block set.
- Generic parsing does not capture generated metadata. Forged `data-echo-*`
  attributes therefore remain inert without the trusted manifest capability.

## Reconcile and rollback behavior

Generated reconciliation runs in one GRDB transaction. It validates the incoming
identity set before mutation, preserves user color/hidden/visual state, retains
unchanged synthesized anchor/word-timing/EPUB-timeline rows, clears those derived
rows only when source text or kind changes, removes obsolete generated rows only
for the same audiobook, and replaces TOC consistently. Duplicate IDs,
cross-book collisions, malformed identity, and injected transaction faults fail
closed.

Before a generated import mutates rows, Echo captures the prior generated block,
TOC, synthesized anchor, word-timing, and EPUB-derived timeline state with
streaming cursors and explicit per-table, total-row, and encoded-byte limits.
Notes, bookmarks, and non-EPUB timeline rows are deliberately outside the
snapshot because reconciliation does not mutate them. Snapshot restore validates
book ownership and collisions, then runs transactionally.

Task 12 now distinguishes generated import attempt from commit:

- validation, extraction, bounded snapshot capture, or reconcile transaction
  failure before return leaves article rows untouched and preserves the original
  failure classification;
- a returned generated receipt must contain a rollback snapshot;
- a later failure restores the prior file, prior shelf record, prior trusted
  generated import, and exact snapshot;
- failure of that exact library recovery records and throws
  `library_recovery_failed`.

## TDD and confirmed fixes

- The initial focused tests failed before V38, trusted identity, reconciliation,
  and stable-ID behavior existed.
- Reorder coverage demonstrated the former order-derived identity behavior before
  stable slots were introduced.
- Adversarial coverage was added for forged metadata, wrong package evidence,
  malformed href/slot/index/kind/text, duplicate/missing blocks, cross-book
  collision, injected transaction rollback, and bounded snapshot limits.
- A Task 12 service regression exposed that the new recovery catch initially
  converted Task 11's `missing_image_asset_mapping` into `build_failed`.
  Successful recovery now preserves the original error code, while failed
  library recovery remains distinct.
- A final classification RED proved that snapshot capture failure before mutation
  was incorrectly reported as `library_recovery_failed`. Explicit committed
  state fixed it. The paired restore-validation test proves that a genuinely
  failed exact snapshot recovery still reports `library_recovery_failed`.
- Exact-SHA specification and adversarial review of `deb22537` found one
  confirmed defect: generated code blocks wrote `data-code-language`, but the
  trusted parser read only CSS language classes and rejected a valid generated
  EPUB with a non-nil language. A real builder-to-preflight-to-import integration
  test failed with `buildFailed` before the production change, then passed after
  trusted parsing began consuming `data-code-language`.
- The code-language attribute remains capability-gated. Generic parsing ignores
  a forged `data-code-language` attribute, while the trusted in-memory identity
  still validates the exact expected language.
- Reconcile coverage now seeds and asserts a real audiobook bookmark as well as
  the block-linked note, making preservation of both user-owned record types
  explicit.

## Verification

- Final formatted-state `make build-tests`: passed.
- Focused V38 suite: 2/2 passed.
- Focused generated import suite: 10 declared tests passed, with 18 executable
  cases after parameter expansion.
- Generic parser parity: 3/3 passed.
- Generic importer: 6/6 passed.
- Generic code parser: 12/12 passed, including the forged Echo-only language
  attribute regression.
- Task 11 builder: 6/6 passed.
- Task 11 preflight: 5 declared tests passed, with 24 executable cases including
  the 20-case hostile archive matrix.
- Task 12 build service: 18 declared tests passed, with 33 executable cases after
  failure/mismatch expansion.
- Real generated library integration: 2/2 passed, including exact 7-to-6-to-7
  prior-edition restoration and zero observed network requests.
- Real generated code-language integration: 1/1 passed through the production
  builder, preflight, trusted import, and reconcile path; all 8 generated EPUB
  blocks imported and `swift` plus `Code listing.` round-tripped.
- Snapshot capture/restore classification integration: 2/2 passed.
- Final post-review combined affected matrix: 134 declared tests in 21 suites
  passed with
  zero failures. Parameterized failure/hostile matrices expanded beyond that
  declared count. It included migration, generated reconcile, generic
  parser/import, coordinator/scanner/finalizer, TOC/front matter/code/text/XML
  structure, assets, archive path safety, DAO, Task 11, and Task 12 coverage.
- After formatting, the final focused matrix ran 47 declared tests in 7 suites
  covering V38, generated reconcile, Task 12 service, code parsing, both prior
  real integration suites, and the new code-language integration; all passed.
- The actual generic parser/import suites then reran 9/9 in 2 suites.
- Strict Swift format lint on every changed Swift file: passed.
- `git diff --check`: passed.
- Changed-production privacy scan found no networking API, literal endpoint,
  CloudKit, `UserDefaults`, credential/token/secret, or developer-machine path.
- Protected narration, project, and architecture file diff: empty.

One earlier simulator attempt was killed before the new rollback classification
suite established its test connection while another task was concurrently using
simulator resources. During the review fix, two attempts on that same default
simulator were also killed before test discovery. They are recorded as
unavailable, not passing or failing. A separate local simulator then produced
the honest code-language RED, the exact GREEN rerun, and all final matrices.

## Review

Implementer self-review is complete. It confirmed and fixed the two error
classification defects described above and found no remaining confirmed defect.
The first immutable specification and adversarial reviews both failed
`deb22537` on the same code-language defect and found no other confirmed defect.
The confirmed finding is fixed and both exact-SHA re-reviews are requested after
the review-fix commit is frozen.

## Proof status

- Local Task 13 implementation: complete.
- Test-target build, focused simulator tests, combined affected regressions,
  format, diff, privacy, and protected-file checks: passed as listed above.
- Hosted CI: not run by this task.
- Task 11 managed article-image mapping: waiting for the upstream contract;
  image-bearing builds continue to fail closed without refetch or omission.
- EPUBCheck and external-reader compatibility: pending, not reinterpreted as
  passing.
- Physical iPhone/iPad capture and acceptance: pending; the user reported the
  device unavailable and it was not requested or accessed.
- iPhone Mirroring: not attempted.
- CloudKit cross-device proof: pending and outside Task 13.
- Narration integration and shared narration files: not touched; pending Task 14
  and the coordinated dependency.
- M4B generation/playback and human listening: pending; no playback probe ran and
  Mac output remained muted.
- Merge, installation, and release: pending parent integration and repository
  workflow.
