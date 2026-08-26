# Task 6 fix round 3

Resume Task 6 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`0dd44d83`

Four Important gaps remain. Fix them with regressions first. Do not touch the separate Task 5 resource/project dependency.

## 1. Stale cancellation race

- Pass the active extraction ID into every scheduled cancellation closure.
- `cancelActiveWork(extractionID:)` must do nothing unless the token equals `activeExtractionID`.
- A delayed cancellation scheduled by extraction A must never cancel extraction B after A has completed/released single-flight state.
- Add a deterministic production-seam test:
  - inject a cancellation scheduler that captures rather than immediately runs A’s cancellation closure;
  - complete/fail A through its real injected rule compiler so state releases;
  - start B and hold its real rule continuation;
  - run delayed cancellation A;
  - prove B remains active/pending and can complete/cancel independently.
- Apply the same token discipline to navigation, parser, and payload cancellation handlers.

## 2. Image validation CPU/memory bounds

- Force only a genuinely small validation raster/thumbnail (for example 512–1024 maximum dimension), not 16,384.
- Run format integrity, CRC, ImageIO status, and bounded raster validation off the Main Actor. Return only the small `Sendable` validation result.
- Replace bit-at-a-time CRC with a bounded table-driven implementation (one lookup per byte, fixed table) or an equivalent efficient standard-library/system implementation; no ~8x per-bit loop over remote bytes.
- Harden PNG chunk arithmetic against overflow/truncation.
- Enforce PNG structure: one IHDR first, at least one IDAT, all IDAT chunks consecutive, one zero-length IEND last; reject IDAT after any post-IDAT chunk.
- Retain MIME/UTI agreement, dimensions/pixel arithmetic, CRCs, JPEG SOI/EOI, complete status, and bounded immediate rasterization.
- Tests:
  - valid runtime-authored PNG accepted;
  - CRC-corrupted IDAT rejected;
  - CRC-recomputed malformed compressed data still rejected by bounded raster/status when a deterministic fixture can be authored;
  - nonconsecutive IDAT rejected;
  - assert the validation raster limit is small through a production-used configuration seam.

## 3. Independent login signal

- A password input is evidence of a protected field, not an independent login action.
- Require the form-local password input plus an independent login-specific action/heading/label/button/submit signal (`login`, `log in`, `sign in`, `authenticate`, etc.).
- A password-strength/demo/change-password form without an independent login action must remain capturable.
- A real login form inside explanatory `<main>/<p>` content must still classify authentication-required.
- Add both tests.

## 4. Preserve presentation during plain/quarantine recovery

- When no new enrichment is supplied, plain `drainStaging()` must compare only immutable imported identity and preserve existing `contentState`/`warningsJSON`; it must not overwrite them with `ready`/`[]`.
- Quarantine reconciliation must do the same.
- With enrichment supplied, persist/repair the requested deterministic presentation before cleanup.
- Tests:
  - enrich record, interrupt before quarantine, retry using plain `drainStaging()`, verify staging cleanup and unchanged enriched fields;
  - enrich record, interrupt after quarantine, retry through ordinary startup quarantine reconciliation, verify cleanup and unchanged enriched fields;
  - immutable content/package mismatch still fails closed regardless of matching presentation.

## Verification and proof

The round must add behavior-level regressions before production fixes and record genuine RED/GREEN evidence. Run one Task 6 Xcode command at a time:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests`
- `git diff --check`

Preserve:

- exact Task 3 durable/quarantine identity and deletion safety;
- Task 4 readable-state semantics;
- no real network, cookies, credentials, headers, or active content;
- explicit `vendoredSourceUnavailable` until Task 5 packages exact pinned bytes;
- no project, share extension, vendor, narration, or architecture edits.

Commit subject:

`fix: preserve article capture recovery state`

Append “Fix round 3” to `task-6-report.md`, map every item, include exact real receipts, and return only when committed and complete.
