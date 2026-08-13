# Handoff — narration abbreviation expansion

## 2026-08-01 — expansions implemented, unit tests green

Done: `TextNormalizer` now expands `Mt.`, `approx.`, month abbreviations in
date position (day/year required), and the unit symbols `km` (number-aware
singular/plural) and `hrs`. Refused `in.`, `no.`, `min.`, days-of-week, `hr`,
`KM`, lowercase `mt`, and bare `40km`. renderVersion 19 → 20.
`TextNormalizerTests` 21/21 and `NarratedWordAlignmentTests` 5/5 pass.

Next: narrate `readable-record-vol2.epub` on the Release `echo-cli` and confirm
the sidecar still reports 18/18 blocks with word timings (rv19 baseline), then
`make test` and open the PR against `nightly`.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/nervous-swirles-2dec60,
branch fix/narration-abbreviation-expansion. Run the probe narration and check
`sidecar written (N anchors, M with word timings)` reports M == N.
```

## 2026-08-01 — verified end to end, opening the PR

Done: probe render at rv20 gives `sidecar written (18 anchors, 18 with word
timings)` and per-block word counts identical to the rv19 baseline; audit
`g2p.fallback` 5 → 1 (survivor `config.json`, a separate v15 case). `make test`
green (3123 tests / 476 suites). One earlier run failed on
`StudyDeckFMAvailabilityTests` alongside a `malloc: pointer being freed was not
allocated`; it did not reproduce at the same commit and clean nightly behaves
the same, so it is a pre-existing heap-corruption flake, filed separately.

Next: watch hosted CI on the PR.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/nervous-swirles-2dec60,
branch fix/narration-abbreviation-expansion. Check CI on the open PR to nightly.
```
