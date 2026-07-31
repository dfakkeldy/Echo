# Task 6 fix round 4

Resume Task 6 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`06089a91`

The prior reviewer accepted token-scoped cancellation and enriched-field recovery. Three P1 compatibility defects remain. Fix them test-first and keep the round narrow.

## 1. Multi-buffer zlib inflation

- The fixed 8 KiB output buffer is correct; using `inflate(..., Z_FINISH)` for each iteration is not.
- Inflate incrementally with `Z_NO_FLUSH` (or equivalent correct streaming semantics) until `Z_STREAM_END`.
- Reset the small output buffer each iteration, count output with overflow/ceiling checks, and reject any iteration with neither input nor output progress.
- Require `Z_STREAM_END`, all compressed input consumed, and exact expected decompressed byte count.
- Treat `Z_BUF_ERROR` as failure only when it represents no-progress/truncation, not merely a full output buffer with progress.
- Add a valid standards-compliant PNG whose decompressed scanlines require many 8 KiB output buffers, plus truncated/corrupt counterparts.

## 2. Independent login action

- Remove generic `<input type="submit">` as sufficient login evidence.
- An input/button/label/action/heading must itself contain login/auth/sign-in/log-in semantics (including relevant `value`, text, aria-label, name/id/action fields).
- A password-strength, password-demo, or change-password form with `<input type="submit" value="Update password">` must remain capturable.
- A real form with a password input and login-semantic submit/action/heading must still classify authentication-required.
- Add both tests.

## 3. Adam7 PNG support

- Do not reject `interlaceMethod == 1`.
- Calculate exact bounded decompressed bytes for Adam7’s seven passes:
  - pass origins/steps `(0,0,8,8)`, `(4,0,8,8)`, `(0,4,4,8)`, `(2,0,4,4)`, `(0,2,2,4)`, `(1,0,2,2)`, `(0,1,1,2)`;
  - each nonempty pass contributes one filter byte plus packed row bytes per pass row.
- Use overflow-safe arithmetic and the existing pixel/output ceiling.
- Continue to require PNG CRCs, chunk ordering, consecutive IDAT, native zlib completion, exact decompressed count, ImageIO type/status, and bounded immediate rasterization.
- Add an authored valid Adam7 PNG fixture and a corrupted counterpart. Assert the fixture’s IHDR interlace byte is actually `1` so the test cannot silently fall back to non-interlaced output.

## Verification

Add regressions before production changes and record real RED/GREEN receipts. Run:

- `make build-tests`
- `make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests`
- `make test-only FILTER=EchoTests/ArticleImageDownloaderTests`
- `make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests`
- `make test-only FILTER=EchoTests/ReadabilityWebExtractorPolicyTests`
- `git diff --check`

Preserve all previously accepted Task 6 behavior and the separate Task 5 `vendoredSourceUnavailable` dependency. No project, share extension, vendor, narration, architecture, or unrelated edits.

Commit subject:

`fix: accept bounded valid article images`

Append “Fix round 4” to `task-6-report.md` with exact receipts and return only when committed and complete.
