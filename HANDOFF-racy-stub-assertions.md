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

Next: `make build-tests`, then the suite filter below, then push and open a PR
to nightly. The wrapper returned rc 75 "HOLD — outside preferred windows" at
17:24 Sun; it admits work daily 22:00–07:00 and weekdays 09:00–15:00.
Delete this handoff in that PR.

**The suite filter is not the filename.** `ABSBrowseModelTests.swift` declares
two `@Suite` structs — `ABSBrowseModelTests` (line 9) and
`URLProtocolStubLifecycleTests` (line 851) — and the cancellation fix is in the
second one. `FILTER=EchoTests/ABSBrowseModelTests` alone skips it and still goes
green. Run both:

```
make test-only FILTER="EchoTests/ABSBrowseModelTests -only-testing:EchoTests/URLProtocolStubLifecycleTests"
```

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
the two-suite filter above, then push and open a PR to nightly.
```

## 2026-08-16 — Local gates green, PR opened

Done: `make build-tests` → `** TEST BUILD SUCCEEDED **`, 0 errors (the
`weak var model` warning at line 371 is pre-existing; no hunk touches it). Then
the two-suite filter three times: 39 tests in 2 suites passed on every pass,
with `URLProtocolStubLifecycleTests` confirmed started and passed each time, so
the cancellation fix was genuinely exercised. Both ran with
`XBG_ALLOW_NOW=1`, which Dan authorized for this off-hours run.

Full local `make test` was deliberately **not** run: it is ~53 min and CI's
"Build gate + tests" runs the whole EchoTests target on the PR anyway. Hosted CI
is the full gate — report its state, do not assume it from the local runs.

Next: watch CI on the PR. If it is green, delete this handoff file in a final
commit on this branch before merge. If the same two tests fail again, the fix is
wrong rather than incomplete — re-measure, do not add more waiting.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/racy-stub-assertions-a41f,
branch claude/racy-stub-assertions-a41f, PR open against nightly. Next:
gh pr checks --watch on that PR; when green, git rm HANDOFF-racy-stub-assertions.md,
commit, push.
```
