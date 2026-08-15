# Handoff — batch queue job removal

## 2026-08-15 — Removal fix written, unverified (build window closed)

Done: Every `batch_queue` row is now removable. `BatchQueueDAO.deleteQueued`
→ `delete(id:)` (any status); `deleteCompleted` → `deleteFinished()`
(completed + failed); `BatchQueueRunner.drain` exits on `CancellationError`
instead of failing the rest of the queue; `MacBatchProcessingService.remove`
cancels the drain when the removed row is the live one; the row shows
`errorMessage` for failed items instead of the stale progress message.
Tests added to `BatchQueueDAOTests` and `BatchQueueRunnerTests`.

Next: Build + test. Blocked — `xcode-build-slot.sh --status` reports HOLD
(Saturday, outside daily 22:00–07:00 and weekday 09:00–15:00 windows).
Needs `make test` AND an out-of-band `Echo macOS` build (the iOS test gate
is blind to the macOS scheme). Then PR `--base nightly`.

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
