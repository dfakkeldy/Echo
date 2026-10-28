# Handoff — macOS library cover cache

## 2026-08-16 — Shared CoverImageCache implemented, Xcode builds pending

Done: `ArtworkCache` was never a cache (only `cachedWatchJPEG`) and is excluded
from the `Echo macOS` + `echo-cli` targets, so it could not be shared. Added
`EchoCore/Services/CoverImageCache.swift` (ImageIO/CoreGraphics only, no `#if`,
no pbxproj edit), pointed `LibraryCoverImage` and `ArtworkCache.loadImageFile`
at it, added `EchoTests/CoverImageCacheTests.swift`. Standalone `swiftc`
typecheck passes on both the macOS and iOS SDKs under the project's Swift 6
settings. No Xcode build yet — the slot admits work from 22:00.

Next: run `make test` and the macOS scheme build through the slot wrapper, then
push and open a PR with `--base nightly`.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-echo-ux-c62409,
branch claude/blissful-almeida-d80238. Run `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test`,
then the macOS scheme build, then push and open a PR with --base nightly.
```

## 2026-08-16 — Builds blocked on the swap floor, not the schedule

Done: work committed at 868d5af8. Dan authorised `XBG_ALLOW_NOW=1`, which
cleared the *schedule* gate; the *resource* gate then held on its own and that
override does not bypass it. Cleared 19 orphaned CoreSimulator processes
(~927 MB, device was not even booted), which unblocked a different session's
2.5-hour retry loop on `epub-identity-fork`. Free swap has since sat at 454 MB
against a 512 MB hard floor; remaining RAM is user apps, nothing agent-owned.
A retry loop (`scratchpad/verify-cover-cache.sh`, 90×60s) is polling the slot
for: macOS scheme build, `make echo-cli`, `make build-tests`,
`make test-only FILTER=EchoTests/CoverImageCacheTests`. Deliberately did NOT
regenerate the 6-week-stale ARCHITECTURE.md — it would add 191 unrelated lines.

Next: Dan chose to open the PR now and let CI be the signal, with the retry loop
still polling for local macOS/echo-cli coverage that CI does not provide.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-echo-ux-c62409,
branch claude/blissful-almeida-d80238. Check the PR's CI, and read
scratchpad/verify-progress.log for the macOS + echo-cli builds CI cannot cover.
```
