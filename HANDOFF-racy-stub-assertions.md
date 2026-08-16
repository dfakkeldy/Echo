# Handoff — time-bounded waits in the ABS browse tests

## 2026-08-16 — Fix committed, Xcode gate deferred by the slot wrapper

Done: Fixed the two CI flakes from run 31953248232, both in
`EchoTests/ABSBrowseModelTests.swift`. (1) `canceledSuspended…` had no wait
before its `== 0` assertion; added the same 50_000-yield wait the arming check
above it uses. (2) `NextAsyncGate.waitUntilSuspended` and the two inline
`FirstProjectionGate` spins now poll a wall-clock deadline and sleep instead of
spinning. Commit a2474171 on `claude/racy-stub-assertions-a41f`, off
origin/nightly 4b64dbe5. Not pushed.

Measured with standalone `xcrun swiftc` harnesses in the session scratchpad
(`spinharness/`, v1–v7), because the build slot was unavailable all session:
the pending-entry window is a median 16 yields / max 485 and always closes;
the fixed shape is 0 failures in 300 runs vs 181 in 200 unfixed; a 50_000-yield
budget is worth ~200 ms of wall time when the poll does not touch the actor it
waits on, which is why the gates timed out; the rewritten gates track a main
actor blocked 300/800/2000 ms and still throw when the work never happens.
`cancellationAfterResumeRemovalPreventsLateDelivery` was checked and
deliberately left alone — `resume()` removes the entry synchronously.

Next: `make build-tests`, then `make test-only FILTER=EchoTests/ABSBrowseModelTests`,
then full `make test`. The wrapper returned rc 75 "HOLD — outside preferred
windows" at 17:24 Sun; it admits work daily 22:00–07:00 and weekdays
09:00–15:00. Then push and open a PR to nightly. Delete this handoff in that PR.

Also open, deliberately out of scope: an audit confirmed racy assertions on
`URLProtocolStub.requests` for the shared `"default"` scope in
`AudiobookshelfServiceAuthTests` (75, 106, 149), `…LibraryTests` (163, 269),
`…ProgressTests` (45), `ArticleURLCaptureServiceTests` (304) and
`ABSDownloadProgressTests` (77) — a cross-suite scope-collision bug, not this
missing-wait bug. Separate change.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/racy-stub-assertions-a41f,
branch claude/racy-stub-assertions-a41f, commit a2474171 unpushed. Next:
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
(after 22:00, or with XBG_ALLOW_NOW=1 if Dan asks for an off-hours run), then
make test-only FILTER=EchoTests/ABSBrowseModelTests, then full make test, then
push and open a PR to nightly.
```
