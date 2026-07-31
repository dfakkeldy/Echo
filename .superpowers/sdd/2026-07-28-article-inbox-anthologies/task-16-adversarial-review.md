# Task 16 exact-SHA adversarial review

Reviewed implementation: `6fc253538f70f0e54249905fec5298e8cbcb7050`

Verdict: **FAIL**

## Confirmed findings

1. **Important — Mutable records are effectively create-only.**
   System fields/change tags from successful and fetched records are discarded.
2. **Important — Failed sends are not resolved or rescheduled.**
   App-actionable errors are classified but their exact changes are not
   requeued.
3. **Important — An older in-flight success can delete a newer save.**
   Outbox acknowledgement uses only record name and operation, with no
   generation token.
4. **Important — One-sided remote anthology updates become recovered copies.**
   There is no pending-local or last-synced-base check.
5. **Important — Credential-bearing provenance URLs can be uploaded.**
   Rendered Safari envelopes bypass the network policy, and canonical/query
   values are stored and encoded unchanged.
6. **Important — Durable sync state is not scoped to an iCloud account.**
   Pending private data from account A can be seeded into account B after a
   switch.
7. **Important — Fetched-apply failure can advance the durable checkpoint.**
8. **Important — Canonical but semantically invalid revision JSON can become
   current.**
9. **Important — Deleted-zone recovery does not repopulate acknowledged local
   records.**
10. **Minor — Failed fetched transactions can leave managed package/cover
    orphans.**
11. **Minor — Directory entries bypass the ZIP entry-count limit.**

## Verify-only notes

- Confirm that the future user-facing sync-off path fully stops automatic sync.
- Define whether a referenced remote capture delete remains local-only or is
  restored to the server.
- Define managed-file reclamation after acknowledged remote deletion.

## Proof boundaries

No live CloudKit, account-switch, cross-device, physical-device, hosted CI,
merge, installation, or release proof was supplied.
