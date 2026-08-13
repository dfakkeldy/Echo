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

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/echo-narration-test-426822,
branch fix/schema-v41-stranded-repair. Check CI on the PR to nightly; if the
Apple build slot is free, run:
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- bash -c 'make build-tests && make test-only FILTER=EchoTests/SchemaV41Tests'
```
