# Handoff — fix nightly release train (EchoTests type-check budget)

## 2026-07-31 — Root cause established

Done:
- Failing gate is `Release Trains` ▸ "Build & ship train" (exit 65), compiling
  EchoTests. Error: `#expect` macro expansion at
  `EchoTests/NarrationServiceTests.swift:1006:9` (commit 33c17fda) —
  "unable to type-check this expression in reasonable time".
  At current nightly head 0c6d8dbb the same code is at lines 1318–1321.
- Culprit: `#expect(retryCalls.reduce(0) { $0 + $1.chunk.g2pInputText
  .components(separatedBy: link).count - 1 } == 1)` in
  `qualityRetrySplitsOnlyTheResolvedPronunciationFragment`.
  `plannedCalls` elements are labeled tuples `(chunk:voice:)`, which compounds
  the solver cost inside `#expect`'s instrumented expression tree.
- **Environment is the trigger, not a code change.** The file last changed
  2026-07-14; failures began 07-25. `ci.yml` runs on `macos-26` → Xcode **26.6**;
  `release-trains.yml` runs on `macos-15` → Xcode **26.3**. Commit 33c17fda
  passed CI run 30401514115 (26.6) and failed train run 30445674022 (26.3).
- The train was already red before 07-25 for a *different* 26.3-only error
  (main-actor isolation, fixed by #473 on 07-24). Same structural gap.

Next:
- Split the expression; survey the file with
  `-Xfrontend -warn-long-expression-type-checking=500`; PR to `nightly`.
- Flag to Dan: the PR gate cannot protect the train while the two run different
  Xcode majors. Note `release-trains.yml` only takes effect from `main`, so any
  workflow-level pin needs a separate hotfix — out of scope for this PR.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/bold-heisenberg-202939
Branch claude/bold-heisenberg-202939 (base origin/nightly).
Next: split the #expect at EchoTests/NarrationServiceTests.swift:1318, then
run `make build-tests` and `make test-only FILTER=EchoTests/NarrationServiceTests`.
```

## 2026-07-31 — Fix implemented, focused suite green

Done:
- Hoisted both compound conditions in
  `qualityRetrySplitsOnlyTheResolvedPronunciationFragment` out of `#expect` into
  local bindings (`linkOccurrences: Int`, `everyRetryKeepsTheLinkIntact`).
  Assertions unchanged. One file, +18/−9.
- `make build-tests` → `** TEST BUILD SUCCEEDED **`, 0 errors.
- `make test-only FILTER=EchoTests/NarrationServiceTests` → 48 tests passed.
- Swept the build with `-Xfrontend -warn-long-expression-type-checking=500`.
  **Caveat:** local Xcode is 26.6 (same as the *passing* PR gate), where this
  expression is <500ms and warns not at all. Only 3 hot spots repo-wide:
  `ReaderTab.swift:392` 986ms, `PronunciationPlannerTests.swift:77` 616ms
  (also an `#expect`). The sweep cannot predict what 26.3 rejects — do not read
  it as clearing the file.
- Gotcha: `xcodebuild OTHER_SWIFT_FLAGS=…` on the command line *replaces* the
  value for every target and breaks swift-collections. Use
  `OTHER_SWIFT_FLAGS='$(inherited) …'`.

Next:
- Full `make test`, then PR to `nightly`, watch `gh pr checks`.
- DoD (a TestFlight build newer than 0.6 (30)) needs merge to `nightly` + a
  train run — Dan's call, not reachable from the PR alone.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/bold-heisenberg-202939
Branch claude/bold-heisenberg-202939. Fix committed.
Next: gh pr create --base nightly, then gh pr checks --watch.
```
