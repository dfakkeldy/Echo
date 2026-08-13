# Handoff — Schema V41 stranded-database repair

## 2026-08-13 — Fix implemented, standalone-verified, PR opened

Done:

- Confirmed the bug in GRDB 7.11.1 source: `appliedMigrations` filters
  `grdb_migrations` to *registered* ids, so the out-of-order guard never fires
  and V25+ run alone on a V1–V23 database.
- Added `Schema_V41` (`v41_repair_squashed_baseline_gap`): idempotent
  `voice_memo` + index recreate, `note.epub_block_id` add gated on
  `db.columns(in:)`. Extracted `DatabaseService.makeMigrator()` as the test seam.
- Added `EchoTests/SchemaV41Tests.swift` (4 tests) + CHANGELOG entry.
- Verified at runtime via a standalone SwiftPM harness compiling the real
  `Schema_V1.swift` + `Schema_V41.swift` against the real GRDB checkout:
  16/16 checks pass, including an empirical proof that
  `registerMigration("v1_create_schema", merging:)` does **not** repair.

Next:

- Local `make build-tests` + `make test-only FILTER=EchoTests/SchemaV41Tests`
  never got the Apple build slot (held 4h+ by an unrelated `ns-marks-the-spot`
  build; weekday window closes 15:00). Hosted CI "Build gate + tests" is the
  standing gate — confirm it passed, or re-run the local gate after 22:00.
- Device-verify on Dan's stranded install: record a feed voice memo, confirm the
  row persists and the memo list populates.

## 2026-08-13 — CI compile failure fixed

Done:

- First CI run failed with 2 errors, both "errors thrown from here are not
  handled" in `#expect` macro expansions (SchemaV41Tests lines 86–87). Cause:
  swift-testing decomposes binary expressions to report both operands, so a
  `try` inside an optional chain across `==` lands in a non-throwing closure.
  `#expect(try db.tableExists(…))` is fine; `#expect(try X.fetchOne(…)?.y == z)`
  is not. Fixed by hoisting the fetches into local `let`s.
- Extended the scratch harness with a **swift-testing test target** mirroring the
  real test file (real `Schema_V1`/`Schema_V41`/`VoiceMemoRecord`/`NoteRecord`
  sources, local `makeMigrator()` seam). Reproduces this exact error class in
  ~12s instead of an 8-minute CI round-trip. 3/3 pass.

## 2026-08-13 — Local Apple gate PASSED

Done:

- The build slot freed at 14:41 (after the fix commit, so it built corrected
  source). `make build-tests && make test-only FILTER=EchoTests/SchemaV41Tests`
  ran on the iOS simulator: **4/4 SchemaV41Tests passed**,
  `** TEST EXECUTE SUCCEEDED **`.

Next:

- Confirm the re-run of CI "Build gate + tests" passes (full EchoTests suite —
  the local run was filtered to SchemaV41Tests only).
- Device-verify on a genuinely stranded install.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/echo-narration-test-426822,
branch fix/schema-v41-stranded-repair. Check CI on the PR to nightly; if the
Apple build slot is free, run:
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- bash -c 'make build-tests && make test-only FILTER=EchoTests/SchemaV41Tests'
```
