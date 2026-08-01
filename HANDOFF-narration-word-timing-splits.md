# Handoff — narration word timings lost on em dash / hyphen / CamelCase

## 2026-08-01 — root cause found, fixed, probe green

Done: Two distinct root causes, both confirmed by instrumented `echo-cli` runs on
`isolate/probe.epub`. (1) Misaki gives an intra-word hyphen the phoneme `" "` and
inserts the same break inside a CamelCase compound, so `KokoroWordTimer` counted
more spoken groups than authored words (9 vs 7, 9 vs 6) and dropped the chunk;
fixed with `PlannedSynthesisChunk.authoredWordGroupCounts` + group merging in the
timer. (2) `TextNormalizer` rewrote `" — "` to `", "`, deleting a whitespace
token, so rendered rows (12) no longer matched source words (13) and the sidecar
capture guard refused them; fixed by normalizing to `" , "`. Probe went 7/4 → 7/7
with every block's count equal to its source word count. Tests added in
`EchoTests/AuthoredWordPhonemeGroupingTests.swift` (+ timer/normalizer suites);
negative control confirms they fail without the fix.

Next: rebase on `origin/nightly` (parallel v14 agent in same directory), bump
`NarrationFileNaming.renderVersion` (audio bytes change via the normalizer), run
`make test`, push, PR `--base nightly`.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/dazzling-sutherland-ceefb9,
branch claude/dazzling-sutherland-ceefb9. Run `git fetch origin && git rebase
origin/nightly`, bump NarrationFileNaming.renderVersion to the next unused number
with a changelog line, run `make test`, then push and open a PR with base nightly.
```
