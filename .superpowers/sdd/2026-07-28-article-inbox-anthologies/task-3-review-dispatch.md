# Task 3 specification and quality review

Review Task 3 first for exact specification compliance, then adversarially for crash consistency, trust-boundary validation, security/privacy, concurrency, and test quality. This is task-scoped, not the final branch review.

## Requested work

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-brief.md`

Binding constraints:

- The staging writer must encode and bounds-check before writing a hidden partial package, atomically publish the UUID directory, and write the empty `complete` marker last.
- On iOS the staged directory must use complete-until-first-user-authentication file protection without breaking macOS/watchOS compilation.
- The durable store must require the marker; validate directory/envelope UUID agreement, schema version, byte limits, and SHA-256; then atomically publish and verify `snapshot.json`.
- The ingestion service must create the durable package first, insert the database row second, and remove staging only after both succeed.
- Retry after a crash must be logically idempotent. A matching existing row plus matching durable digest is recovered success; any inconsistency fails closed and retains complete staging.
- Incomplete packages are ignored. A failed destination write retains complete staging. Successful import leaves no staging residue and no duplicate rows.
- Temporary roots must be injected in tests; tests must not touch real App Group, Application Support, Caches, or iCloud storage.
- Preserve privacy: only the narrow envelope may be persisted—never cookies, authorization headers, form values, browsing history, scripts, frames, or embeds.
- Preserve iOS 18, macOS 15, watchOS 11, Swift 6 strict concurrency, and default Main Actor isolation.
- No Xcode project, narration file, or architecture-document changes were allowed.
- Tests were required first. The meaningful RED proof was a build-for-testing missing-symbol failure. The implementer reports successful build and zero exit from focused commands, but the focused xcresult bundles lacked a final `Info.plist`; do not interpret that limitation as per-test runtime proof.

Pay particular attention to adversarial interruption windows:

- failure before/after partial-directory creation;
- collision with an existing final staging directory;
- failure after durable snapshot publication but before DB insertion;
- failure after DB insertion but before staging deletion;
- existing row whose digest or metadata does not match the staged/durable data;
- directory traversal or UUID/path ambiguity;
- digest computation over different bytes than those ultimately persisted;
- deletion behavior when staging paths are symlinks or otherwise malformed.

## Implementer report

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-report.md`

Treat execution claims as unverified.

## Diff

- Base: `b7793161`
- Head: `079153b468f0b249af8fbc354c1910352587f88b`
- Package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-3-review-b7793161..079153b.diff`

Read the package once; it contains commits, stat, and full diff. Do not run git commands or crawl the codebase. Inspect unchanged code only for a specific named risk the diff cannot answer, and name that focused check.

This review is read-only. Do not mutate files, the index, HEAD, or branch. Do not rerun reported tests unless a specific unresolved code doubt requires one focused test.

## Output

Begin directly with:

### Spec Compliance

- `✅ Spec compliant` or `❌ Issues found`, with file:line evidence.
- List `⚠️ Cannot verify from diff` separately.

Then:

### Strengths

Concrete evidence with file:line references.

### Issues

Critical, Important, and Minor. For each: file:line, defect, impact, and fix direction.

### Assessment

- `Task quality: Approved` or `Task quality: Needs fixes`
- One or two sentences of technical reasoning.

Both spec and quality verdicts are mandatory.
