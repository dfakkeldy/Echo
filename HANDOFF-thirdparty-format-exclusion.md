# Handoff — ThirdParty formatter exclusion

## 2026-08-01 — Hook exclusion implemented, tests green, PR opened

Done: `swift-format-on-edit.sh` now skips `ThirdParty/**` (path-component match,
absolute + relative arms); two test cases added (vendored file byte-identical;
`MyThirdPartyHelpers/` still formatted). `make hooks-test` 39/39. Negative
control confirms the new test fails without the fix. Real `Lexicon.swift` is
byte-identical through the hook (old hook would have churned 1,327 lines).

Not done (deliberate): `indentConditionalCompilationBlocks` left at `true` —
flipping it reflows 93 of 95 currently-clean `#if` files (18,182 lines).

Next: watch CI on the PR, then merge to `nightly`; delete this file in that PR.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/serene-pasteur-091600
on branch claude/serene-pasteur-091600. Check CI status on the open PR against
nightly and report it; if green, nothing else is pending.
```
