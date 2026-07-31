# Task 3 fix round 1 review

Re-review only Task 3 fix round 1. This is read-only.

## Original findings to adjudicate

1. **Critical:** capture staging used process-local Application Support instead of the App Group.
2. **Important:** existing-row recovery compared only SHA-256 and could delete staging despite conflicting deterministic metadata/package path.
3. **Important:** stale partial or published-without-marker packages permanently blocked same-UUID retry.
4. **Important:** the file store allocated the complete untrusted envelope before enforcing its byte bound.
5. **Important:** enumeration/import/deletion did not reject symlinks or prove standardized direct-child containment.
6. **Minor:** deterministic interruption/collision, metadata conflict, oversized input, malformed marker, and symlink tests were missing.

## Inputs

Read the appended Fix round 1 section:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-report.md`

Treat execution claims as unverified. In particular, the build-for-testing is reported successful, but final focused commands again lack complete Swift Testing receipts. One intermediate run executed seven ingestion tests and exposed two digest failures; canonical sorted-key staging was then added. Do not claim post-fix runtime success from an incomplete receipt.

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-fix1-review-079153b..f05af117.diff`

- Base: `079153b468f0b249af8fbc354c1910352587f88b`
- Head: `f05af11702e488af46df6f478ed24a9221c046a9`

Read the package once. Do not run git commands or crawl the repository. Inspect unchanged code only when a specific unresolved risk requires it, and name that focused check.

Adversarially verify:

- The App Group handoff and private durable-root separation.
- Exact deterministic record comparison on recovery.
- Safe handling of stale partial/incomplete paths without overwriting a complete package.
- Marker-last proof seam and collision behavior.
- Preallocation bounds plus revalidation around bounded reads.
- Direct-child containment, regular-file/real-directory requirements, symlink rejection, and deletion-time revalidation.
- Canonical encoding is applied to the exact bytes hashed and persisted.
- Regression tests actually exercise each claimed fix.
- The fix did not weaken data protection, ordering, privacy, Swift 6 isolation, or the specified public interfaces.

## Output

For each original finding, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical or Important breakage introduced by the fix. Keep environment-limited runtime proof separate from code correctness.

End with exactly one verdict:

- `Fix round: All findings addressed, no new Critical/Important breakage`
- `Fix round: Findings remain`
