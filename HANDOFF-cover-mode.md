# Handoff — "Cover" appearance mode

## 2026-08-10 — implementation done, sim gate pending

Done: fourth appearance option "Cover" (System/Light/Dark/Cover).
`CoverThemeBuilder.preferredScheme(for:)` picks the scheme whose wash band
needs least reshaping of the cover's anchor tone (edge > primary > B/W pole;
tie zone L≈0.57 ±0.04 and balanced B/W → nil → system).
`PlayerModel.coverPreferredScheme` exposes it; both iOS
`colorScheme(for:)` mappers handle "Cover"; picker row + footer added.
macOS untouched (theme files excluded there; unknown value degrades to
System). Headless probe green incl. 11 new picks; all 4 reference books → light.

Next: sim CoverThemeBuilderTests green → commit, push, PR `--base nightly`.

Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71
# branch claude/cover-mode-appearance; gate:
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- bash -c 'make build-tests && make test-only FILTER=EchoTests/CoverThemeBuilderTests'
```
