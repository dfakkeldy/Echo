# Handoff — cover-theme follow-ups (three PRs off `nightly`)

Three follow-ups to PR #525 (cover-theme accent promotion), each its own
branch + PR off `origin/nightly`, smallest first.

1. Dark-yellow amber rotation — `feature/cover-theme-dark-amber-rotation`
2. Book-detail + chapter-sheet theming (iOS) — not started
3. Widget + watch background-ramp roles — not started

## 2026-08-08 — item 1 verified green

Done: `CoverThemeBuilder` compresses the 70–110° OKLCH band toward its warm
edge (14° max) for the DARK background/chip ramp only; accents, the light
scheme, promotion and the drift gate are untouched. 3 targeted tests added;
`make test-only FILTER=EchoTests/CoverThemeBuilderTests` = 20/20.
Next: commit + push + PR to `nightly`, then start item 2.
Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/distracted-yalow-ad102f,
branch feature/cover-theme-dark-amber-rotation. Item 1 is green (20/20).
Push it and open a PR to nightly, then start item 2 (theme BookSettingsView +
ChapterPickerSheet from PlayerModel.coverTheme; ramp goes INSIDE the
NavigationStack).
```
