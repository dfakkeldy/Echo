# Task 6 fix round 2 review

Re-review only the four remaining Task 6 areas. This is read-only.

## Open areas from prior re-review

1. WebKit rule compilation/navigation were not fully tokened/cancellable/single-flight safe.
2. Image validation did not force a reliable bounded decode of corrupted compressed content.
3. Authentication dominance used global tag counts rather than form-local structure.
4. Enriched warnings/state were persisted after staging cleanup, creating permanent loss on interruption.
5. Associated behavior-level proof gaps remained.

Task 5’s missing pinned Readability bundle resource remains a separate open dependency and cannot be closed here.

## Inputs

Read “Fix round 2”:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-fix2-review-90e9d76f..0dd44d83.diff`

- Base: `90e9d76f`
- Head: `0dd44d83`

Read the package once. Do not run git commands, mutate the worktree, or crawl unrelated code.

Adversarially verify:

- one extractor has a true single active extraction identity covering rule, navigation, parser, and payload phases;
- cancellation resumes each real pending continuation once, clears single-flight state, and ignores late callbacks;
- stale navigation callbacks require matching extraction token and exact WebView identity;
- injected rule compiler is narrow and production uses the same continuation state machine tested;
- bounded immediate rasterization plus PNG chunk bounds/order/CRC and JPEG framing do not create unbounded allocation, parser overflow, or false rejection of valid authored fixtures;
- corrupted compressed PNG bytes are deterministically rejected;
- login classification is form-local and handles explanatory main/paragraph text without false negatives while avoiding article false positives;
- combined presentation fields are persisted before cleanup; failure retains staging; post-save interruption/retry converges without refetch, duplication, or mutable-field identity conflict;
- plain Task 3 drain and quarantine reconciliation remain correct;
- tests exercise the real state machines/crash windows, and no new Critical/Important cancellation, data-loss, DoS, privacy, or Swift 6 regression appears.

The report honestly states production changes preceded regressions in this round, so no TDD RED claim exists. Treat execution claims as unverified code-review inputs: build succeeded; image 6/6; URL 7/7; WebKit 4/4; inbox 15/15.

## Output

For each open area, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical/Important breakage. Keep Task 5 integration separate.

End with exactly one:

- `Fix round: All code findings addressed, no new Critical/Important breakage; Task 5 integration remains`
- `Fix round: Findings remain`
