# Handoff — macOS cover-derived colour scheme

## 2026-08-16 — Implementation complete, Xcode builds still owed

Done: Ported the iOS cover-theme pipeline to macOS. `ColorMetrics` gained an
AppKit `rgb(_:)` branch and `CoverThemeBuilder.build` is ungated; the four
pipeline files were removed from the macOS target's pbxproj exclusions;
`MacPlayerModel` now extracts `CoverSignature` on its existing off-main artwork
pass and memoizes a `CoverTheme`; `MacCoverTint` (EchoCore, testable) resolves
the tint; `MacTriPaneView` applies it plus a player-bar wash; the Library shows
real covers; the Appearance footer is honest again. Verified by `swiftc`
type-check under both SDKs and a run harness that confirms every behavioural
assertion (vivid promotion 200→20, contrast floors 3.05–4.31 vs floor 3.0).
Two settings that previously lied — Theme Color ▸ Artwork and Vivid Cover
Accent — now have real consumers, each pinned by a test.

Next: `make test`, then build both macosx schemes (the membership change is
unproven until they compile), then manual Mac acceptance on a duotone cover, a
near-monochrome cover, and a book with no artwork.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-cover-colors-016824,
branch claude/macos-cover-colors-016824. The macOS cover-theme work is committed
but unbuilt: run `make test`, then
`/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
and `make echo-cli`, then open a PR to nightly.
```
