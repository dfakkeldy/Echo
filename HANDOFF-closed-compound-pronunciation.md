# Handoff — closed-compound pronunciation (rv14 gate never fired)

## 2026-08-01 — fix verified locally, ready to push

Done: root cause = `Lexicon.transcribeClosedCompound` admitted a split only when
the *left* component was in a curated 97-entry allowlist, so `fog`/`tide`/`boat`
compounds discarded every split before the lexicon was consulted. The rule was
live, not dead — `headphone`/`hyperparameter` always worked. Fix: a split now
accepts semantic evidence from *either* constituent via a reviewed
`compoundHeads` set; compound provenance is threaded to the audit as
`g2p.compound.<word>`; renderVersion 16 → 18 (17 is claimed by the
concurrent dash-normalization PR #488). Gold-corpus fires 3,775 → 5,745
with avg distance to truth 0.42 → 0.35; 6 pinned negatives still rejected.
`make test` green, `make echo-cli` green, CLI audit JSON confirms all three.

Next: pushed and PR opened against `nightly`; watch CI. If PR #488 merges
first, rebase — the changelog comment block will conflict textually, but v18
stays valid.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/stoic-cohen-ef6320
on branch claude/stoic-cohen-ef6320. Check CI on the closed-compound PR against
nightly; if PR #488 landed first, rebase on origin/nightly, keep
NarrationFileNaming.renderVersion at 18, and re-run `make test`.
```
