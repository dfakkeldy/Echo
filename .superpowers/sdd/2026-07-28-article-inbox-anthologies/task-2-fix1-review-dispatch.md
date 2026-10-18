# Task 2 fix round 1 scoped re-review

Re-review only the prior finding and this fix diff. Do not perform a fresh task review.

## Task

Brief:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-brief.md`

## Finding under verification

- Important — `Shared/Database/DAOs/AnthologyDAO.swift:17-20` saved the entire `AnthologyRecord`, including DAO-managed `next_stable_slot` and `latest_build_revision`. A stale caller-owned record could lower the counters, reuse removed stable slots, collide with existing slots, and regress build bookkeeping. The save path must preserve the stored counters on update, and a regression test must prove stale save cannot break monotonic slots.

The deferred Minor about broader schema introspection is outside this fix round.

## Fix

Read the appended fix report:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-report.md`

- Fix base: `105a03da`
- Head: `b7793161`
- Diff package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-fix1-review-105a03da..b7793161.diff`

Read the package once. Do not run git commands. The review is read-only: do not mutate files, index, HEAD, or branch.

Confirm the report names the covering tests and their RED/GREEN output, but do not rerun them unless the fix diff raises a specific unanswered doubt.

## Output

### Finding Verdicts

- Verdict the finding `ADDRESSED` or `NOT ADDRESSED` with file:line evidence.

### New Breakage in the Fix Diff

List Critical, Important, or Minor breakage with file:line evidence, or `None`.

### Out-of-Scope Observations

List non-blocking observations outside the fix diff, or `None`.

### Verdict

- `Fix round: All findings addressed, no new Critical/Important breakage`
- or `Fix round: Findings remain open`, listing them.

Begin directly with the finding verdict; no process preamble.
