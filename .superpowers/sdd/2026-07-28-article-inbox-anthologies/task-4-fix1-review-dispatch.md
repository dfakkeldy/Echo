# Task 4 fix round 1 review

Re-review only Task 4 fix round 1. This is read-only.

## Original findings

1. **Important:** namespace-prefixed and unlisted active elements could bypass the blacklist and leak text into allowed spoken content.
2. **Important:** rejected/missing image candidates consumed the retained-image limit and emitted empty image blocks.
3. **Important:** caption-only readable content was classified as `captureFailed`.
4. **Minor proof gaps:** external entity was declared but not referenced; DOM-element and rejected-image exhaustion paths were not tested; revision hash sensitivity/invariance tests were weak.

## Inputs

Read the “Fix round 1” section:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-report.md`

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-4-fix1-review-99279a26..f3226d42.diff`

- Base: `99279a26`
- Head: `f3226d42`

Read the package once. Do not run git commands, mutate the worktree, or crawl unrelated code.

Adversarially verify:

- namespace processing/local-name normalization cannot turn untrusted non-XHTML elements into admitted XHTML;
- explicit structural/transparent allowlists are fail-closed, and skipped subtrees cannot leak nested text/attributes/captions/URLs;
- allowed wrappers preserve legitimate readable text without accidentally admitting active containers;
- rejected images neither emit blocks nor spend the retained-image limit, while a valid later image/text survives;
- caption-only content has a deterministic representation and readiness aligned with readable hashing;
- the `&xxe;` reference cannot become file contents or entity text;
- DOM-element bounds are genuinely exercised during parsing;
- hash tests prove semantic sensitivity and metadata/ID/URL invariance;
- no new Critical/Important parser-state, nesting, bound, identity, concurrency, or privacy regression was introduced.

Treat the claimed build and 11/11 plus 5/5 receipts as unverified execution evidence. The excluded corrupt/stopped runs are not proof.

## Output

For each original finding, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical or Important breakage. End with exactly one:

- `Fix round: All findings addressed, no new Critical/Important breakage`
- `Fix round: Findings remain`
