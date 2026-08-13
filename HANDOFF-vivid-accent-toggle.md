# Handoff — Vivid Cover Accent toggle

## 2026-08-12 — implemented, publishing

Done: extractor keeps per-bucket vivid-core stats (top-chroma quartile);
`CoverThemeBuilder.resolve/build` gain `vividAccent:` (default false =
shipped behaviour); vivid tries the core seed at floor 0.11 then falls
back to the mean seed, so it can never lose a promotion the means earn.
`SettingsManager.vividCoverAccent` (default off) + toggles in iOS
Appearance (with `syncToWatch()`) and Mac Appearance pane. PlayerModel
caches key on the flag. 5 new tests. Headless probe (real sources)
15/15; 626-cover sweep byte-identical to the validated prototype
(208 change: 172 <30° re-seeds, 28 ≥60° captures).

Next: push, PR to nightly, CI gate. Sim visual QA at a build window.

Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71
# branch claude/vivid-accent-toggle; PR open --base nightly; if CI green
# it is Dan's to merge. Delete this handoff in the PR that closes the task.
```
