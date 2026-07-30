# Task 6 fix round 4 review

Re-review only the final three Task 6 compatibility findings. This is read-only.

## Open findings

1. `Z_FINISH` with a fixed 8 KiB output buffer rejected valid multi-buffer PNG streams.
2. Generic `<input type="submit">` counted as independent login evidence.
3. Valid Adam7-interlaced PNGs were rejected.

Task 5’s missing pinned parser bundle remains a separate open dependency.

## Inputs

Read “Fix round 4”:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-fix4-review-06089a91..e1120e9d.diff`

- Base: `06089a91`
- Head: `e1120e9d`

Read the package once. Do not run git commands, mutate the worktree, or crawl unrelated code.

Adversarially verify:

- incremental inflation resets the fixed output buffer, makes progress, handles buffer conditions correctly, and terminates only on exact output count, all input consumed, and `Z_STREAM_END`;
- truncated streams, extra compressed input, decompression bombs, no-progress loops, and integer overflow fail closed;
- valid multi-buffer fixture genuinely emits more than 8 KiB decompressed data;
- login signals require semantic login/auth/sign-in text in action/control/label/heading and cannot be satisfied by a generic submit alone;
- real login forms remain detected and password-update/demo forms remain capturable;
- Adam7 pass origins/steps, empty-pass handling, packed row-byte calculations, filter bytes, overflow checks, and exact total output are correct for all bit depths/color channel counts already admitted;
- authored Adam7 fixture asserts IHDR interlace byte 1 and is independently valid; corrupt counterpart fails;
- no new Critical/Important compatibility, DoS, privacy, or data-loss regression appears.

Execution claims are unverified code-review inputs: build passed; URL 10/10; image 9/9; inbox 16/16; WebKit 5/5; diff check clean.

## Output

For each finding, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical/Important breakage. Keep Task 5 separate.

End with exactly one:

- `Fix round: All code findings addressed, no new Critical/Important breakage; Task 5 integration remains`
- `Fix round: Findings remain`
