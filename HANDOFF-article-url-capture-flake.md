# Handoff — ArticleURLCaptureServiceTests flake on nightly

## 2026-08-01 — Root cause found, fix applied, verification pending

Done:
- Diagnosed `stopsReadingResponseAtTwelveMiB()` (red on nightly runs 30637013991,
  30658102196, 30679684020, and PR #488 run 30709839057).
- Proved with standalone `xcrun swiftc` harnesses (not guesswork):
  1. `stopLoading()` fires exactly once for a **successful** load too — it is
     URLSession teardown, not cancellation. So `cancelledRequestCount == 1`
     detected no regression at all; it passes even if bounded reading is removed.
  2. A `URLProtocol` double can never observe an early stop: `startLoading()`
     hands the whole body to URLSession before the delegate sees a byte
     (100% delivered at 1x/2x/4x the limit, even with 2 ms/chunk pacing).
  3. The counter is process-global and shared with `ArticleImageDownloaderTests`
     and `ArticleInboxIngestionServiceTests`, which drive the same
     `ArticleBoundedURLLoader`. `waitForCancellation` only guarantees `>= 1`
     while the assertion demands `== 1`; foreign increments reproduce the
     failure 25/25 with observed counts of 2 and 3.
- Fix: deleted the vacuous assertion + the `cancelled` counter and
  `waitForCancellation` that existed only to serve it; `stopLoading()` is now an
  empty no-op, matching every other URLProtocol double in the repo
  (`URLProtocolStub.swift`, `StubURLProtocol.swift`). `.responseTooLarge` — the
  real, deterministic assertion — is unchanged. 13 insertions, 35 deletions.
- NOTE: the SwiftFormat Edit hook reflows this whole file (230/160 lines,
  reindents the `#if canImport(WebKit)` block). Apply edits here via Bash, not
  Edit/Write. See memory `echo-swiftformat-edit-hook`.

Next:
- `make build-tests`, then run the three ArticleWorkshop suites; commit; PR to
  `nightly`; report hosted CI state.
- Machine had 2-3 concurrent xcodebuilds from other sessions — serialize.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/nervous-swirles-2dec60,
branch claude/nervous-swirles-2dec60 (based on origin/nightly 1e4de54f).
Fix is applied and unstaged. Next: wait for any other xcodebuild to exit, then
run `make build-tests` followed by the ArticleWorkshop suites, and open a PR
with --base nightly.
```

## 2026-08-01 — Verified locally, pushing

Done:
- `make build-tests` → `** TEST BUILD SUCCEEDED **`.
- Ran the three suites sharing `ArticleURLProtocol`
  (`ArticleURLCaptureServiceTests`, `ArticleImageDownloaderTests`,
  `ArticleInboxIngestionServiceTests`) 3x back to back. Read from the
  `.xcresult`, not the exit code: 38 passed / 0 failed / `"result": "Passed"`
  in all three runs.
- Machine had 2 competing xcodebuilds from other sessions; the repo's
  concurrent-build hook blocked one attempt. Serialized and waited each time.

Next:
- Open PR `--base nightly`; watch `Build gate + tests`; delete this file in the
  same PR before merge.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/nervous-swirles-2dec60,
branch claude/nervous-swirles-2dec60. Fix committed (dee36ce0) and locally
verified. Next: report hosted CI state on the PR, then drop this handoff file.
```
