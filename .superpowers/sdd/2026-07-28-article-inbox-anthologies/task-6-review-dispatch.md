# Task 6 specification, networking, media, and quality review

Review Task 6 first for exact specification compliance, then adversarially for URLSession/WebKit cancellation, redirects, bounded allocation, authentication classification, image decoding/localization, privacy, Swift 6 isolation, and tests. This is task-scoped and read-only.

## Requested work

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-brief.md`

Important execution context:

- Task 5 is dependency-blocked because Global Pronunciation owns first integration of `Echo.xcodeproj/project.pbxproj`.
- Therefore the pinned Readability resource is not currently bundled. Task 6 intentionally fails closed with `vendoredSourceUnavailable`; default runtime URL extraction is **not functional yet**.
- Judge that as an explicit unmet Task 5 integration/acceptance dependency, not as a passing Task 6 runtime state. Also identify whether Task 6 code introduces any additional defect independent of that dependency.

Binding constraints:

- Only credential-free normalized HTTP(S) URLs, including every redirect.
- Ephemeral injected URLSession with no persistent cookies, credentials, caching, or stored headers.
- Maximum five followed redirects and an incremental twelve-MiB response cutoff before unbounded allocation.
- Successful HTML/XHTML response MIME only.
- Deterministic authentication-required classification with the exact Safari message.
- Nonpersistent WebKit; page-authored JS disabled; all subresources blocked; supplied HTML only; pinned script evaluated in client world; cancellation/navigation continuation exactly once.
- Image localization accepts only normalized HTTP(S), bounded JPEG/PNG whose MIME, decoded type, dimensions, byte limits, and destination containment agree. Atomic non-overwriting writes.
- Image rejection leaves readable text and adds warning.
- No later snapshot load refetches.
- Preserve Task 3 durable/quarantine protocol and Task 4 sanitizer/domain contracts.
- No project, share-extension, narration, architecture, or dependency changes.

Adversarially inspect:

- sixth redirect, redirect loops, relative redirects, auth-bearing URLs, cross-scheme targets, and redirect counter scoping;
- response validation before data append, Content-Length tricks, chunked over-limit bodies, completion/cancellation races, delegate/session retention;
- login classifier false negatives/positives and whether it can save login markup as an article;
- WebKit content-rule compilation failure, navigation failure/cancellation, double continuation, and whether base URLs can still trigger any load;
- JavaScript source/result decoding and attacker-controlled values crossing `[String: Any]`;
- MIME parameter/casing, JPEG/PNG magic vs ImageIO type, zero/huge/overflow dimensions, total budgets, duplicate names, symlink/path escape, partial writes;
- exact warning/state preservation when images fail;
- tests use only injected protocol and actually exercise all seven required behaviors.

## Implementer report

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Treat execution claims as unverified. Focused runs exited zero but have no complete per-test receipt.

## Diff

- Base: `f3226d42`
- Head: `ee5b6b72`
- Package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-review-f3226d42..ee5b6b72.diff`

Read the package once. Do not run git commands or crawl unrelated code. Inspect unchanged code only for a specific named risk the package cannot answer, and name it.

## Output

Begin directly with:

### Spec Compliance

- `✅ Spec compliant`, `⚠️ Code compliant with deferred integration`, or `❌ Issues found`, with file:line evidence.
- List `⚠️ Cannot verify from diff` separately.

Then:

### Strengths

Concrete evidence with file:line references.

### Issues

Critical, Important, and Minor. Each needs file:line, defect, impact, and fix direction. Keep the known missing bundled parser integration separate from new defects.

### Assessment

- `Task quality: Approved`, `Task quality: Approved pending Task 5 integration`, or `Task quality: Needs fixes`
- One or two sentences of technical reasoning.

Both spec and quality verdicts are mandatory.
