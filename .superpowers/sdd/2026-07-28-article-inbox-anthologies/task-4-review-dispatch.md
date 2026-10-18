# Task 4 specification, security, and quality review

Review Task 4 first for exact specification compliance, then adversarially for hostile-XHTML handling, URL normalization, bounded parsing, deterministic identity/hashing, immutable edits, Swift 6 isolation, and test quality. This is task-scoped and read-only.

## Requested work

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-brief.md`

Binding constraints:

- `XMLParser` is only a streaming structural reader with external entity resolution disabled. No WebKit, script evaluation, subresource/image fetch, arbitrary DOM/HTML preservation, or local/network side effect is permitted.
- Emit only the exact `ArticleBlockKind` vocabulary as typed text/normalized fields.
- Reject scripts, forms, frames, event handlers, `javascript:`, `file:`, data URLs, unknown schemes, credentials, active markup, and external entity content.
- Resolve relative URLs against source first; retain only normalized absolute HTTP(S) candidates.
- Enforce centralized element/block/image bounds during parsing, before unbounded structures are created.
- Parser/malformed/limit warnings must remain visible and produce Ready, Review suggested, or Capture failed according to usable text.
- Initial sanitation assigns `article-<capture UUID>-b<stable ordinal>` once. Cleanup never renumbers blocks.
- Revision validation must reject unknown IDs and invalid trim boundaries; apply trim before exclusions; preserve base order; overlay metadata immutably; reset to original sequence.
- Snapshot hash must cover canonical sorted-key JSON. Clean revision hash must deterministically cover only readable/spoken content with unambiguous structure.
- Preserve iOS 18, macOS 15, watchOS 11, Swift 6 strict concurrency, default Main Actor isolation, privacy limits, and existing Task 1–3 interfaces.
- No new dependency, project-file change, narration change, or architecture-document change was allowed.

Adversarially inspect:

- XML entity declarations and parser delegate behavior cannot expose entity contents or perform I/O.
- Disallowed element text is not accidentally accumulated into an allowed ancestor.
- Nested/malformed elements cannot smuggle attributes/text or corrupt block boundaries.
- Scheme parsing is case/whitespace/encoding safe; relative resolution cannot reintroduce credentials/local URLs.
- Bounds apply to parser work as well as emitted output where the spec requires it.
- Stable ordinals/IDs cannot collide or shift after filtering.
- Snapshot hash does not recursively hash itself or omit semantically relevant values.
- Revision hash does not accidentally include metadata/presentation-only values or omit spoken text.
- Recipe validation is atomic: an invalid reference cannot yield partial edits.
- Tests actually assert the malicious/structural outcomes rather than only state/count summaries.

## Implementer report

Read:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-report.md`

Treat execution claims as unverified. The earlier overlapping focused run was interrupted and explicitly excluded. The report claims final serial receipts: build succeeded, sanitizer 7/7, revision 3/3.

## Diff

- Base: `cd2ff5e9`
- Head: `99279a26`
- Package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-review-cd2ff5e9..99279a26.diff`

Read the package once; it contains commits, stat, and full diff. Do not run git commands or crawl the codebase. Inspect unchanged code only for a specific named risk the diff cannot answer, and identify that focused check.

## Output

Begin directly with:

### Spec Compliance

- `✅ Spec compliant` or `❌ Issues found`, with file:line evidence.
- List `⚠️ Cannot verify from diff` separately.

Then:

### Strengths

Concrete evidence with file:line references.

### Issues

Critical, Important, and Minor. Each needs file:line, defect, impact, and fix direction.

### Assessment

- `Task quality: Approved` or `Task quality: Needs fixes`
- One or two sentences of technical reasoning.

Both spec and quality verdicts are mandatory.
