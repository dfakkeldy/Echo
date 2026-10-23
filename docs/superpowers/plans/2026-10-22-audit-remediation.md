# October 22 audit remediation

**Goal:** Resolve the 30 active findings in the October 22 audit while preserving existing book data and platform behavior.

**Architecture:** Keep the current concrete services. Make SQL authoritative for bookmarks after successful legacy reconciliation, publish reader/shelf data with revision checks, and derive immutable indexes when snapshots load. Keep expensive file, database, image and matching work off the UI actor.

**Constraints:** iOS 18, macOS 15, watchOS 11; no new dependencies, migration edits, private book fixtures, release promotions or renderer installation. Preserve the original audit. Apple commands use the build scheduler.

- [ ] Bookmark ownership and ordered async persistence: 5.8, 7.11, 9.1. Test SQL reopen, rapid A/B switching, legacy recovery and deletion without resurrection.
- [ ] Complete scan results, whole-book duration and batched rescan: 3.1, 5.5, 5.6. Test multitrack duration, failed discovery and cancellation before reconciliation.
- [ ] Reader snapshots, search, capture and caches: 5.4, 5.7, 7.1, 7.2, 7.6, 7.8, 7.10, 8.4, 9.1. Test stale loads, search changes, save failures and retained memo assets.
- [ ] Shelf snapshot and merge guards: 5.10, 7.3, 7.7, 7.14. Test hidden text, failed eligibility, duplicate IDs and deterministic edition grouping.
- [ ] Alignment cancellation and timeline indexes: 3.5, 3.6, 5.9, 7.4, 7.5. Test multichannel silence, cancellation, overlapping rows and front matter.
- [ ] Bounded images and narration preparation: 7.9, 7.12, 7.13. Test image size, reused-cell results and unchanged QA/normalization outputs.
- [ ] Source diagnostics and references: 2.1, 2.4, 3.4, 4.2. Preserve behavior; validate through compiler diagnostics.
- [ ] Run relevant checks, inspect cross-platform and database changes, deliver a ready PR to nightly, fix introduced failures and merge after required CI passes.

Regression coverage accompanies behavioral changes. The local baseline build was scheduler-deferred with exit 75; hosted CI must supply native compilation and test evidence. Verification results and finding-to-fix links belong in the final remediation record.
