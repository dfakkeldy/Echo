# Handoff — abs-download-corruption

## 2026-08-27 — diagnosis + repair implemented, awaiting build window

Done: Root cause of "ABS books turned into UUID shells": `audiobook.id` is the
folder's absolute container URL; iOS moved the app data container, stranding
every ABS row (proof: simulator DB has 8 rows for one Gatsby folder, one per
container UUID). Wrote `Shared/Database/ContainerPathRepair.swift` (open-time
re-key + placeholder merge + embedded id/path rewrites), wired into both
disk-backed `DatabaseService` inits, tests in
`EchoTests/ContainerPathRepairTests.swift`. Both files parse clean.
Schema reviewer findings all applied: per-book transactions, in-tx old-row
recheck, /Containers/ guard, study_plan_item + study_export_state +
anthology_build.epub_path coverage, JSON-escaped media_json rewrite, dangling
track_id null-out; 7 tests incl. path-pass, multi-generation, foreign-path.
Next: build slot HOLD until 22:00; background job bw7elevs5 runs
`make build-tests` + `make test-only FILTER=EchoTests/ContainerPathRepairTests`
when the window opens. Hosted CI verifies the PR meanwhile.
Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/old-worktrees-salvage-d4912c
# branch claude/audiobookshelf-download-corruption-4abdf2
# next: check test results, commit, push, open PR to nightly
```
