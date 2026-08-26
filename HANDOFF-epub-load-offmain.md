# Handoff — EPUB load path off the main actor

## 2026-08-25 — implementation complete, build pending

Done:
- Diagnosed the "can't hit play while an EPUB book loads" report (iPhone 12):
  every open of an EPUB book ran, synchronously on the main actor —
  full timeline_item rebuild (`TimelineIngestionService.ingestItems`),
  `AlignmentService.recalculateTimeline` + `WordTimingMaterializer.materialize`
  (one row per word of the whole book), `EPUBAutoImportScanner` scan (decoding
  every block just to test emptiness), first-open unzip+parse import, and
  `ReaderFeedViewModel.reload()` (all blocks + all word rows again).
- Fix: `@concurrent` off-main bodies with same-signature `@MainActor` wrappers
  (`TimelineIngestionService.ingestItems`, `EPUBAutoImportScanner.scanAndImportIfNeeded`
  / `importEPUBFile`), `nonisolated` on the DAO/record/parse-chain types,
  `EPubBlockDAO.hasVisibleBlocks` EXISTS query replacing 3× full-decode
  `.isEmpty` checks, `EPUBAssetStorage` now holds `DatabaseWriter?`,
  `ReaderFeedViewModel.reload()` builds state off-main and applies in one shot
  (`reloadSync()` kept for tests; 8 test call sites renamed).

Next:
- `make build-tests` green, then targeted suites:
  `make test-only FILTER=EchoTests/EPUBAutoImportScannerTests` (+ EPUBImportTests,
  EPUBTOCImportTests, EPUBFrontMatterImportTests, AudiolessEPUBImportTests,
  ReaderBreadcrumbTests, ReaderActiveBlockTrackScopingTests), then full `make test`.
- CHANGELOG entry under [Unreleased]; commit; PR against `nightly`.

Resume:
```
Worktree: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/agitated-banach-768298
Branch: claude/epub-loading-delay-iphone-45b187
Next: check make build-tests result, run the targeted EchoTests suites above, commit, PR to nightly.
```
