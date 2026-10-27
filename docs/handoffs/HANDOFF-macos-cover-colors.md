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

## 2026-08-16 — All three local gates green, PR open

Done: `Echo macOS` build, `make echo-cli`, and `make test` all pass
(`** TEST SUCCEEDED **`). `make test` first failed with `cannot find type
'CoverSignature'` while compiling `MacCoverTint.swift` into the widget
extension. Cause: `membershipExceptions` inverts direction. `Echo
WidgetExtension` does not own the `EchoCore` synchronized group, so for that
target the list reads as *includes* — the entry added the file to the widget
without its dependencies instead of keeping it out. Fixed by deleting the
entry; the echo-cli entry is a true exclusion and stays. Verified at the
compiler-input level via `Build/Intermediates.noindex/.../*.SwiftFileList`,
which is the authoritative per-target file list and answers membership
questions without a build.

Rebased onto origin/nightly eb1ed641 (#573), which reworked this same
`MacTriPaneView` from three columns to two-plus-inspector. One file, three
hunks: kept nightly's inspector wiring verbatim (20 EchoTests files scan this
file as text) and attached the wash to the transport. All three gates re-run
green after the rebase. PR https://github.com/dfakkeldy/Echo/pull/575 → nightly.

Next: CI on #575, then manual Mac acceptance — a duotone cover, a
near-monochrome cover, and a book with no artwork, plus the same book side by
side with iOS to check the AppKit `rgb(_:)` colour-space branch. Delete this
handoff in the commit that closes the task.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-cover-colors-016824,
branch claude/macos-cover-colors-016824, PR #575 open to nightly. All local gates
are green. Next: `gh pr checks 575`, then run the Mac app and check the accent on
a duotone, a near-monochrome, and a coverless book.
```

## 2026-08-16 — CI green on #575

Done: CI failed once with 2 of 3872 tests, both in `EchoTests/ABSBrowseModelTests.swift`
(`canceledSuspendedRequestIsRemovedAndScopeCanBeCleaned`, `staleSnapshotRetains…`)
— Audiobookshelf networking, untouched by this PR, and zero cover-theme tests
failed. An unmodified rerun of the same commit passed in 43m29s, so they are
flakes. PR #575 is now CLEAN and MERGEABLE. Root cause filed separately: the
`== 0` assertion after `request.cancel()` has no bounded spin, unlike the `== 1`
read a few lines above it.

Next: manual Mac acceptance is the only gate left — duotone, near-monochrome,
and coverless books, plus an iOS side-by-side for the AppKit `rgb(_:)` branch.
Delete this handoff in the commit that closes the task.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-cover-colors-016824,
branch claude/macos-cover-colors-016824, PR #575 open to nightly, CI green.
Next: run the Mac app and check the accent on a duotone, a near-monochrome, and a
coverless book; compare the same book against iOS.
```
