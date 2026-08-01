# Handoff — narration number-expansion word timings

## 2026-08-01 — Root cause reproduced and fixed, tests green

Done:

- Reproduced with `echo-cli narrate` on a 10-paragraph probe EPUB:
  `sidecar written (11 anchors, 5 with word timings)`. Instrumented all three
  guards: **Guard #3** (`HeadlessNarrationRunner.captureEntries`) fires for
  number/abbreviation expansion, not Guard #2. Guard #1 fired separately for the
  #488 hyphen class (`well-worn`, and `$45` -> "forty-five").
- Root cause: `WordTimingMaterializer.materializeSynthesizedChapter` built rows
  from the **narrated** text, so a block with an expanded number got more rows
  than its source text has words. Readers index the source basis, so surplus
  rows fell out of range and survivors highlighted the wrong word; Guard #3
  correctly refused to export them (`words: []`).
- Fix: new pure `NarratedWordAlignment` (prefix/suffix trim + LCS, fail-closed)
  maps narrated words back onto source words. Rows are now materialized on the
  source basis; `refineWithSynthesis` folds synthesis timings with the same
  counts. No `renderVersion` bump — synthesized audio bytes are unchanged.
- Touches none of PR #488's files, so the two do not collide.
- `NarratedWordAlignmentTests` + `SynthesizedWordRowBasisTests` + the existing
  `WordTimingSynthesisRefineTests`: 22 runs, 0 failures.

Next:

- Full `EchoTests` regression run, then the end-to-end probe re-run.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/distracted-yalow-ad102f
on branch claude/distracted-yalow-ad102f. Run the full EchoTests suite, then
`make echo-cli` and re-run scratchpad/run_probe.sh; confirm the sidecar line
reports 9 of 11 anchors with word timings and open the PR with --base nightly.
```

## 2026-08-01 — Verified end to end, ready for review

Done:

- Full `EchoTests`: 3242 passed, 0 failed, 3 skipped (read from `.xcresult`).
- Rebuilt `echo-cli` and re-ran the probe:
  `sidecar written (11 anchors, 9 with word timings)` — up from 5. The two still
  missing are the intra-word-hyphen class #488 fixes, not this one.
- `word_timing` rows for the numeric blocks are now source-basis with real
  synthesis times: `It|cost|1,200|dollars.`, source `synthesis`. The sidecar
  gives "1,200" one span (6.466 -> 7.373) covering the whole spoken phrase, so
  the in-app karaoke drift is fixed alongside the missing sidecar words.
- Composability check over the 66 inputs `TextNormalizerTests` pins: 63/66
  resolve on nightly, 66/66 with #488's normalizer.

Next:

- Open the PR against `nightly`; watch CI.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/distracted-yalow-ad102f
on branch claude/distracted-yalow-ad102f. The work is committed. Open/refresh the
PR with --base nightly and report hosted CI status.
```
