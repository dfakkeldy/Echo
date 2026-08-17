# Handoff — fast doc-contract lane

## 2026-08-17 — doc contracts moved off Xcode; docs-only PRs skip the build gate

Done: Ported `SettingsHelpPathTests` + `TimelineLanguageCleanupTests` (pure text
scans, no app imports) to `Scripts/doc_contracts/`, deleted the Swift originals,
added `make doc-contract-test`, and gated CI's 11 Xcode steps behind a unit-tested
`docs_only` classifier with a pbxproj tripwire for bundled Markdown.
10 Python tests pass in 0.017s; a mutation test on the real `ARCHITECTURE.md` fails
as intended. `make build-tests` was NOT run — the slot wrapper held it at 07:50
(gap between the 22:00-07:00 and 09:00-15:00 windows); this PR is not docs-only, so
its own CI gate compiles the deletion.

Next: watch CI on the PR. If it is green, nothing else is outstanding.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/doc-contract-lane,
branch chore/fast-doc-contract-lane. Check CI on the open PR; if the Swift build
step failed, the cause is the deletion of the two EchoTests files.
```
