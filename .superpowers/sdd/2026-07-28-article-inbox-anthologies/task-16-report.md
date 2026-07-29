# Task 16 report — private Article Workshop CloudKit sync

Date: 2026-07-29

## Outcome

Task 16 is locally implemented at verified implementation commit
`6fc253538f70f0e54249905fec5298e8cbcb7050`, based exactly on frozen commit
`132f38a21857643455a545f654d44c74b4b97fe3`.

Article Workshop now has additive V39 sync state and a durable outbox, bounded
private-zone CloudKit record codecs, deterministic conflict preservation, a
transactional fetched-record database apply path, and a lazy `CKSyncEngine`
driver. Local captures, cleanup revisions, and anthology projects remain
authoritative and usable without starting CloudKit.

## Migration and durable state

- V39 creates only `article_sync_state` and `article_sync_outbox`, using the
  schema and `save`/`delete` operation values required by the brief.
- `DatabaseService` registers V39 after V38.
- Fresh-install schema coverage verifies the exact columns.
- A real V38-to-V39 upgrade preserves an existing Article Workshop capture.
- Real `CKSyncEngine.State.Serialization` Codable data round-trips through the
  DAO as an opaque binary property-list blob without creating a `CKContainer` or
  `CKSyncEngine`.
- Outbox batches commit atomically. Save acknowledgments clear only matching
  saves, failed rows remain pending, and stale save acknowledgments cannot clear
  a delete tombstone. Delete tombstones clear only after a delete
  acknowledgment.

## Record and asset boundary

- The custom private zone is `EchoArticleWorkshop.v1`.
- Deterministic record identities are:
  `EchoArticleCapture/capture.<UUID>`,
  `EchoArticleRevision/revision.<UUID>`, and
  `EchoAnthology/anthology.<UUID>`.
- Captures place the package body only in a ZIPFoundation-compressed `CKAsset`;
  article body fields are absent from scalar record fields.
- Capture metadata and digests are bounded and validated. The local package
  snapshot digest is checked before upload and after managed installation.
- Revision metadata and recipes use sorted canonical JSON with bounded scalars
  and validated IDs/digests.
- Anthologies use a dedicated cloud DTO. Local `cover_path` and generated
  `latest_build_revision` are not encoded. `next_stable_slot` is retained
  deliberately because it is conflict-safe authoring state that prevents
  removed chapter positions from being reused after cross-device edits.
- Optional covers are separate validated `CKAsset` values.
- Record-type allowlists reject unknown/raw-path fields. Canonical re-encoding
  rejects unknown nested manifest keys.
- Archive validation rejects unsafe paths, symlinks, duplicate paths,
  over-count and decompression-limit violations. Downloaded assets are copied
  out of CloudKit-owned temporary URLs before the event callback returns.
- Generated EPUB, narration audio, M4B, credentials, cookies, logs, raw errors,
  local package paths, and local cover paths do not enter CloudKit records.
  `narration_voice_id` remains in anthology entries because it is user-authored
  project configuration, not generated narration media.

## Fetched changes and conflicts

- A fetched event is decoded and validated as a batch. Capture packages and
  covers are installed into managed Article Workshop storage, then all database
  changes commit in one GRDB transaction.
- A failing later database change rolls back earlier rows from the same fetched
  batch.
- Immutable cleanup revision siblings are retained. A direct child may become
  current; a sibling does not overwrite the local active revision.
- Concurrent anthology manifests preserve the active local project and create a
  recovered copy of the remote ordering.
- Recovered anthology and entry UUIDs are SHA-256-derived and deterministic, so
  replaying the same conflict does not multiply copies.
- Recovered projects are transactionally added to the durable save outbox.
- Remote deletes do not override a pending local change. Referenced captures are
  preserved rather than violating anthology ownership.

## `CKSyncEngine` driver

- The production `CKContainer` and `CKSyncEngine` are constructed only inside
  the explicit actor-owned `start()` boundary.
- The existing `iCloud.com.echo.audiobooks` container's
  `privateCloudDatabase` is the only database used. The public community-anchor
  service is not referenced.
- Startup adds a pending save for the custom record zone and seeds engine
  pending changes from the durable outbox.
- Every `.stateUpdate` persists `State.Serialization`.
- Fetched records are passed to the transactional batch applier.
- Sent saves and deletes acknowledge only their matching outbox operations.
  Failed records remain in both the outbox and engine state for retry.
- The failable async `RecordZoneChangeBatch` initializer receives only pending
  changes accepted by `context.options.scope`, leaving CloudKit to enforce the
  combined 250-record batch cap.
- Quota, network, server-record conflict, authentication, missing-zone, and
  partial-failure outcomes map to stable codes without persisting raw error
  text.
- Account changes update status only and never delete Article Workshop data.
- Outgoing asset copies are removed after success, failure completion, or
  cancellation; source packages and covers remain local.

## TDD receipts

The required tests were written before the first production types. The three
initial `make test-only FILTER=...` commands could only execute the previously
built test bundle and therefore did not discover the new suites. The decisive
fresh:

```text
make build-tests
```

failed with 38 compile diagnostics for missing `Schema_V39`,
`ArticleSyncDAO`/pending-change types, `ArticleCloudRecordCodec`, conflict
types, and the engine/driver types. That is the initial required RED.

Additional behavior-first RED receipts:

- `make build-tests` failed because `ArticleSyncDAO.applyFetchedChanges` and
  fetched change cases did not exist. After implementation, the transactional
  commit and rollback tests passed.
- `make build-tests` failed because `ArticleFetchedCloudBatchApplier` did not
  exist. After implementation, the callback-to-managed-install test passed.
- The codec suite failed 1/5 because an injected `packagePath` field was
  accepted. Per-record allowlists made the suite pass 5/5.
- The rebuilt codec suite failed 1/6 because `latest_build_revision` was still
  encoded. The dedicated cloud anthology DTO removed it and the suite passed
  6/6.
- An early state-serialization test incorrectly constructed a `CKContainer` in
  an unentitled simulator host. The host reported the missing CloudKit
  entitlement and restarted; this was a real test-design failure, not a pass.
  The test was replaced with a deterministic real
  `CKSyncEngine.State.Serialization` Codable fixture and no longer constructs
  CloudKit runtime objects.

## Final local verification

All commands ran serially against the dedicated local simulator
`EchoTest-iPhone-17` (`4774318C-1444-4660-BF3E-EA00025AEAFA`) with no live
CloudKit calls:

- Final formatted-state `make build-tests`: passed with
  `** TEST BUILD SUCCEEDED **`.
- `ArticleCloudRecordCodecTests`: 6/6 passed.
- `SchemaV39ArticleSyncTests`: 5/5 passed.
- `ArticleSyncConflictResolverTests`: 6/6 passed.
- Affected persistence suites:
  `SchemaV37ArticleWorkshopTests`,
  `SchemaV38GeneratedChapterKeyTests`,
  `ArticleWorkshopDAOTests`, and `AnthologyServiceTests`: 40/40 passed.
- Final post-build matrix: 57 tests in 7 suites passed with zero failures
  (6 codec plus 51 schema/conflict/affected tests).
- Strict Swift format lint for every changed Swift file: passed.
- `git diff --check`: passed.
- Privacy scan found exactly one `CKContainer` construction, inside the explicit
  start path, using only `.privateCloudDatabase`; it found no public/shared
  database, public sync service, logger, raw error output, unchecked Sendable,
  unsafe isolation, detached task, or semaphore in the Task 16 implementation.
- The changed-file set contains only the nine Task 16 source/test files. The
  protected narration files, project file, and `ARCHITECTURE.md` have empty
  diffs.

One final codec attempt stalled before app launch while the dedicated simulator
was shutdown. Only that Task 16 process was stopped; the simulator was booted
without opening its frontend, and the one allowed retry reached the product
tests. This was recorded as unavailable infrastructure, not a product failure.

## Self-review and concerns

Implementer self-review is complete. It fixed the fetched-apply gap, raw-path
field acceptance, generated anthology build-state leakage, nondeterministic
recovered entry IDs, and staged-file retry cleanup before the final matrix.

SQLite application is atomic. Managed files are installed immediately before
that transaction, so an injected SQLite failure can leave a validated orphan
package or cover with no database record pointing to it; it cannot expose a
partially committed Article Workshop row. A future housekeeping pass may remove
such unreferenced managed files, but that is not required for local-first data
correctness in Task 16.

## Proof status

- Local Task 16 implementation: complete at
  `6fc253538f70f0e54249905fec5298e8cbcb7050`.
- Local build, focused simulator tests, affected persistence regressions,
  formatting, diff, privacy, and protected-file checks: passed as listed above.
- Live CloudKit private-database/zone/schema operation: not run and not claimed.
- Real quota, authentication, missing-zone, server-conflict, and partial-failure
  delivery: classified and locally tested where deterministic, but live service
  behavior remains pending.
- Physical-device and cross-device acceptance: pending.
- Hosted CI: not run by this task.
- Merge: pending parent integration.
- Installation: pending.
- Release: pending.
