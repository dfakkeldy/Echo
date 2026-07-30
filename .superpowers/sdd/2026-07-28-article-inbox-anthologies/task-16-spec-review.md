# Task 16 exact-SHA specification review

Reviewed implementation: `6fc253538f70f0e54249905fec5298e8cbcb7050`

Verdict: **FAIL**

## Confirmed findings

1. **Important — CloudKit system fields are not persisted.**
   Saves always build a fresh `CKRecord`; neither V39 nor the sent-save handler
   stores successful records' system fields. Later saves can fail indefinitely
   with `serverRecordChanged`.
2. **Important — App-actionable failures are not requeued.**
   Failed records remain in SQLite but are not added back to
   `CKSyncEngine.State`; the outbox is seeded only during `start()`.
3. **Important — Credential-bearing URLs can enter CloudKit.**
   Source and canonical URLs receive byte-count validation only.
4. **Important — Ordinary remote anthology updates become conflicts.**
   Every nonidentical incoming manifest creates a recovered copy, even when
   there is no pending local edit.
5. **Important — Failed fetched batches can be checkpointed past.**
   Decode/install/database failures are swallowed while later engine state
   updates are persisted, so rolled-back valid records may never be fetched
   again.
6. **Important — Capture snapshots are not semantically validated.**
   Package validation checks file shape and digest, but not a real
   `ArticleCaptureEnvelope`, schema, capture ID, or sanitizer contract.
7. **Important — Missing-zone recovery recreates an empty zone.**
   It queues only `saveZone`; acknowledged local records are not repopulated.
8. **Minor — Routine state updates erase `last_error_code`.**

## Verify-only notes

- Prove outgoing staged assets remain alive for the complete cancellation
  boundary.
- Prove account switch/reset cannot leak state between accounts.
- Add a deterministic event seam for state, partial failure, zone loss, staged
  cleanup, and account behavior.

## Verified passes

Lazy private-database construction, custom zone/record names, failable combined
250-record batch construction, additive V39 registration, operation-qualified
tombstone acknowledgments, copied fetched assets, Swift 6 isolation, protected
files, and task scope.

