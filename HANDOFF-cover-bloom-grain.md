# Handoff — ambient cover bloom + wash grain

## 2026-08-10 — implemented, publishing

Done: wash grain (deterministic seeded mid-grey noise tile in
`AdaptiveBackground`, `.overlay` blend, 0.035 light / 0.06 dark) and
ambient bloom (chip-tone blurred ellipse behind player artwork in
`NowPlayingTab`). `WashGrainTests` added; real-source headless compile
of `WashGrain` green (deterministic, band-clean, 64 distinct values).
Local sim slot schedule-held → hosted CI is the compile/test gate.

Next: CI green → Dan merges. Sim screenshots at the 22:00 build window.

Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71
# branch claude/cover-bloom-grain, PR open --base nightly; if CI green,
# offer sim visual QA: build Echo, screenshot player light+dark.
```
