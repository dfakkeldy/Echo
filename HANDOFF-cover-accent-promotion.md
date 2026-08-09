# Handoff — cover-accent-promotion

## 2026-08-08 — promotion + drift gate prototyped, harness-verified

Done: `CoverThemeBuilder` promotes a vivid hue-distinct secondary (chroma ≥0.09,
weight ≥5%, ≥60°) into the accent role, seeded from the cover's observed L/C
(`HueCandidate.lightness`, new) with a ≤0.15-L identity-drift gate; primary-hue
accent moves to `secondaryAccent`. 5 new/2 updated tests. Verified via
`xcrun swiftc` harness compiling REAL sources: all checks pass, floors hold on
both 360° sweeps; promoted hexes: neon `#C7F22C` (leverage dark), plum
`#734D9E`/`#9770C5` (geode).
Next: slot-wrapped `make build-tests` + `make test-only FILTER=EchoTests/CoverThemeBuilderTests` (window 22:00); then device-eyeball on real covers; PR to nightly.
Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71  # branch claude/echo-cover-color-scheme-700b95
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

## 2026-08-08 — simulator pass: promotion VERIFIED on-device

Done: purple+neon m4b in iPhone 17 sim — dark player = purple room + neon
accent `#C3ED2C`-ish (promotion fires); light player = lavender + purple accent
(drift gate refuses neon). Seeding route: File Provider Storage + in-app folder
picker; appAppearance lives in the app CONTAINER plist (device-level `defaults
write` is ignored).
FINDING: extraction runs on the ThumbnailRenderer square composite
(`currentDisplayArtwork`), not the raw cover — blur+margins dilute small
counter-colours (geode vein share 6.9%→4.6%, under the 5% floor → no promotion
for photographic duotones with small accents). Fix = compute CoverSignature
from the SOURCE artwork at load time; separate change.
TRAP: install sim builds from the DerivedData whose info.plist WorkspacePath
matches THIS worktree (`Echo-dpekmwydszdpzycupaorwkjtywyt`) — newest-mtime
picked a Codex worktree's stale binary and promotion "didn't work".
Next: PR to nightly; then the extraction-source follow-up.

## 2026-08-08 — build gate green (user-requested off-hours run)

Done: slot-wrapped `make build-tests` + `make test-only
FILTER=EchoTests/CoverThemeBuilderTests` passed (17/17, TEST BUILD SUCCEEDED);
XBG_ALLOW_NOW=1 per explicit user request. Branch pushed.
Next: simulator eyeball on real photographic covers (bucket-mean chroma may
undershoot the 0.09 promotion floor — if so, that's the percentile-chroma
extractor follow-up), then PR `--base nightly`.
Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71  # branch claude/echo-cover-color-scheme-700b95
# next: run app in iPhone 17 sim, eyeball duotone covers, then gh pr create --base nightly
```

## 2026-08-08 — extraction-source fix implemented (commit 5f5aff2d), awaiting 22:00 window

Done: CoverSignature now extracted from SOURCE artwork at load
(BookmarkArtworkCoordinator), stored in `PlaybackState.sourceCoverSignature`
(iOS-gated), preferred by `PlayerModel.currentSignature` for base artwork;
bookmark artwork keeps per-image extraction; cleared on book/track reset. 5
tests added. macOS CG harness (real OKLCH/ThumbnailRenderer geometry/resolve)
confirms geode fixture: source plum share 10.8% vs composite 3.3% (floor 5%),
promotion flips in both schemes.
Next: slot-wrapped `make build-tests` (background waiter armed for 22:00),
then `make test-only FILTER=EchoTests`; push.
Resume:
```
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71  # branch claude/echo-cover-color-scheme-700b95
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests
```
