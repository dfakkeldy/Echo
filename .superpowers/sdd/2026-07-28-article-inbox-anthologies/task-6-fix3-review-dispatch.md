# Task 6 fix round 3 review

Re-review only the four remaining Task 6 findings. This is read-only.

## Open findings

1. Delayed cancellation from extraction A could cancel replacement extraction B.
2. Image validation used a 16,384 thumbnail and bit-at-a-time Main Actor CRC, risking remote-input memory/CPU DoS; PNG IDAT structure was incomplete.
3. Any password form satisfied its own independent login signal.
4. Plain/quarantine recovery could overwrite enriched warning/state fields with `ready`/`[]`.
5. Corresponding race/structure/login/recovery proof gaps.

Task 5’s missing pinned parser bundle remains a separate dependency.

## Inputs

Read “Fix round 3”:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-fix3-review-0dd44d83..06089a91.diff`

- Base: `0dd44d83`
- Head: `06089a91`

Read the package once. Do not run git commands, mutate the worktree, or crawl unrelated code.

Adversarially verify:

- every scheduled cancellation carries its extraction ID and stale A cancellation is a no-op once B is active;
- the injected cancellation scheduler is narrow and the deterministic test exercises production state with bounded waits;
- image integrity/decode runs off Main Actor, validation thumbnail is truly small, CRC is table-driven, parser arithmetic is bounded, IDAT chunks must be consecutive, and PNG native zlib stream is validated with fixed-memory streaming and exact bounded output;
- zlib/CRC/chunk validation cannot overflow, spin without progress, accept trailing compressed bytes, or allocate based on attacker-controlled expansion;
- valid PNG/JPEG acceptance and malformed/corrupt/nonconsecutive/truncated rejection are not fixture artifacts;
- password forms require an independent login action and demo/strength/change-password forms are not false positives;
- plain direct retry and quarantine reconciliation compare immutable import identity while preserving existing presentation fields;
- enrichment still persists before cleanup and immutable mismatches fail closed;
- tests cover delayed cancellation A→B, image bounds/structure/integrity, password false positive, direct and quarantine enriched recovery;
- no new Critical/Important cancellation, DoS, data-loss, privacy, or Swift 6 regression appears.

Execution claims are code-review inputs, not independently rerun: build succeeded; image 7/7; inbox 16/16; URL 8/8; WebKit 5/5; diff check clean.

## Output

For each open finding, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical/Important breakage. Keep Task 5 separate.

End with exactly one:

- `Fix round: All code findings addressed, no new Critical/Important breakage; Task 5 integration remains`
- `Fix round: Findings remain`
