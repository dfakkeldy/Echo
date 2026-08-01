# Handoff — contiguous word indices on the synthesized fallback

## 2026-08-01 — Fix + regression test pushed (stacked on PR #492)

Done: `materializeSynthesizedChapter`'s unalignable fallback now reuses the
block's already-built `spokenTimings` (contiguous `0..N-1` across every speech
range) instead of `rangeIndex * 10_000 + indexWithinRange`, which also drops a
duplicate interpolation pass. Audited every `word_index` consumer first: all are
sort-and-zip or count-based, so nothing needed the stride. New test
`unalignableMultiRangeBlockKeepsContiguousWordIndices` fails on the old code with
`[0, 1, 2, 10000, 10001, 10002]`. Full `make test` 3243 passed / 0 failed / 3
skipped; `make echo-cli` clean.

Next: PR is based on `claude/distracted-yalow-ad102f` (PR #492) because the
fallback branch does not exist on `nightly`. When #492 merges, GitHub retargets
this PR to `nightly` — confirm that happened, then watch CI.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/stoic-cohen-ef6320,
branch claude/dazzling-leakey-6538ce. Check whether PR #492 has merged; if so
confirm this PR retargeted to nightly and report its CI status.
```
