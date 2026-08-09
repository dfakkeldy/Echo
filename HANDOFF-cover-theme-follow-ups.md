# Handoff — cover-theme follow-ups (three PRs off `nightly`)

Three follow-ups to PR #525 (cover-theme accent promotion), each its own
branch + PR off `origin/nightly`, smallest first.

1. Dark-yellow amber rotation — merged, PR #526 (`d292fb5b`)
2. Book-detail + chapter-sheet theming (iOS) — `feature/cover-theme-sheet-wash`
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

## 2026-08-08 — item 2 green

Done: `CoverThemedSheet` scaffold owns the `NavigationStack` so the ramp always
lands inside it; Book Settings + chapter picker adopt it. A sheet needs BOTH
the in-stack ZStack ramp and `.presentationBackground` — with only the first,
the simulator still measured `#1C1C1E`. Book Settings verified on the iPhone 17
sim (`#382A5B`/`#322356`/`#302055`); 3 tests green.
Next: item 3 (widget + watch background ramp). Watch seam is
`ContentView.artworkBackground`'s flat-black fallback.
Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/distracted-yalow-ad102f.
Item 2 PR is open. Start item 3: carry backgroundTop/backgroundBottom hex over
the app-group + WatchState channels (mirror artworkAccentColorHex's 10 sites),
consume in Echo Widget/Views + Echo Watch App ContentView.artworkBackground.
Run cross-platform-parity-reviewer before opening the PR. Device acceptance via
iPhone Mirroring, not the simulator.
```
