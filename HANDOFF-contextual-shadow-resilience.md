# Handoff — contextual shadow-layer resilience

## 2026-08-01 — Fix committed, PR opened against nightly

Done: One transient FM `GenerationError -1` zeroed `SystemLanguageModel.contextSize`
for the whole process, disabling the Task-10 shadow layer and mislabelling every
later batch `contextTooLarge`. Fixed three ways: last-known-good `contextSize`
fallback; new `ContextualModelFailure.contextWindowUnavailable` plus
`processFinalAttempt` preserving the original `terminalFailure`; char-per-token
budget recalibrated 2 → 3. `make test` and `make echo-cli` both pass.

Next: Watch hosted CI on the PR. `renderVersion` deliberately NOT bumped
(shadow-only layer cannot change a phoneme).

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/nervous-swirles-2dec60
on claude/sharp-cohen-b793be. Report hosted CI status for the open PR.
```
