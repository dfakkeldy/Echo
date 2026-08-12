# Handoff — watch progress + cover bugs

## 2026-08-11 — diagnosis + implementation complete, build/tests pending

Done: Both watch bugs root-caused and fixed (11 files). Bug 1 (frozen progress):
no phone-side `sessionReachabilityDidChange` + single unretried `requestState`
pull → added reachability push in `WatchSyncManager`, 3× retry in
`WatchViewModel`. Bug 2 (lost cover): `onBookmarksChanged` →
`invalidateCache()` nils `baseWatchThumbnailData` mid-book → added narrow
`invalidateBookmarkArtwork()` (2 call sites), self-heal in
`updateCurrentDisplayArtwork`, and watch-behind thumbnail resend
(`watchArtworkSeq` in requestState → `resendThumbnailIfWatchBehind`).
Tests added: WatchThumbnailTransferPolicyTests, WatchCommandRouterTests,
BookmarkArtworkCoordinatorTests (+1 watch-target test not run by `make test`).
Next: verify `make build-tests` result, run the 3 EchoTests suites via
`make test-only`, commit `fix(watch):`, push, PR `--base nightly`.
Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/echo-narration-test-426822,
branch claude/watch-app-progress-cover-bugs-db78d5. Check build-tests output,
then: xcode-build-slot.sh -- make test-only FILTER=EchoTests/WatchCommandRouterTests
(then WatchThumbnailTransferPolicyTests, BookmarkArtworkCoordinatorTests).
Green → commit fix(watch), push, gh pr create --base nightly.
```

## 2026-08-11 — build green, tests green, parity clean; publishing

Done: `make build-tests` succeeded after one fix (#require can't wrap a
mutating call — store result first). All 3 EchoTests suites pass (20 tests).
Parity reviewer: no blockers; applied its one suggestion (replenish watch
retry budget in `sessionReachabilityDidChange`). Watch-target test compiles
but is NOT run by `make test` (iPhone scheme) — noted in PR.
Next: commit `fix(watch):`, push, PR `--base nightly`; device-verify on watch.
Resume:
```
Branch claude/watch-app-progress-cover-bugs-db78d5 in the worktree above.
If PR not yet open: git push -u origin HEAD && gh pr create --base nightly.
After merge: device-verify both bugs on the watch, then delete this file.
```
