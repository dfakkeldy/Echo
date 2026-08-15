# Handoff — batch queue job removal

## 2026-08-15 — Removal fix written, unverified (build window closed)

Done: Every `batch_queue` row is now removable. `BatchQueueDAO.deleteQueued`
→ `delete(id:)` (any status); `deleteCompleted` → `deleteFinished()`
(completed + failed); `BatchQueueRunner.drain` exits on `CancellationError`
instead of failing the rest of the queue; `MacBatchProcessingService.remove`
cancels the drain when the removed row is the live one; the row shows
`errorMessage` for failed items instead of the stale progress message.
Tests added to `BatchQueueDAOTests` and `BatchQueueRunnerTests`.

Verified: `make test` → `** TEST SUCCEEDED **` (full EchoTests, 0 failures),
run under `XBG_ALLOW_NOW=1`. NOTE the first attempt exited 0 having built
nothing — "Build deferred: resource admission failed after preflight"
(pressure 2/2, swapFree 1188MB < warnMin 2048 while Echo was rendering).
`XBG_ALLOW_NOW=1` overrides the schedule, NOT the memory gate. Always grep
the output for `TEST SUCCEEDED`; exit 0 alone proves nothing.

Also verified: `xcodebuild build -scheme "Echo macOS" -destination
'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`,
0 errors. Needed out of band: `make test` never compiles the macOS scheme, so
the view and service edits are invisible to it (and to CI's build gate).

Next: PR `--base nightly`, then delete this file in that PR once CI is green.

Open, separate bug: narration has no intra-chapter resume. The `.partial.m4a`
is deleted on entry and in the `defer` (`NarrationService.swift:965-973`) and
the skip check only tests the final file (`MacBatchProcessingService.swift:361`),
so any chapter longer than one uninterrupted app session restarts from zero
forever. Reproduced on queue id 22 ("book", enqueued 2026-08-02, still on
chapter 2 of 12).

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/great-heisenberg-47ce71
Branch claude/stale-jobs-epub-m4b-alignment-ccbf8f (off origin/nightly bd89de8d).
Run: /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
then the Echo macOS scheme build, then open a PR --base nightly.
```
