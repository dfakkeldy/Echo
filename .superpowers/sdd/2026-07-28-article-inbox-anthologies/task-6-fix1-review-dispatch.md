# Task 6 fix round 1 review

Re-review only Task 6 fix round 1. This is read-only.

## Original findings

1. **Critical:** WebKit content rules omitted document loads and navigation policy allowed iframe/meta-refresh/follow-on navigation.
2. **Critical:** URLSession delegate isolation was unsafe under default Main Actor isolation.
3. **Important:** WebKit navigation/parser/payload cancellation could leave continuations pending or double-resume.
4. **Important:** total image budget did not bound the next transfer.
5. **Important:** check-then-atomic-write could overwrite a raced destination.
6. **Important:** ImageIO metadata did not prove complete decodability.
7. **Important:** authentication classification had `/auth` false positives and was not dominated-content based.
8. **Important:** injected `httpAdditionalHeaders` could send credentials/custom state.
9. **Important:** image warnings/readable state were not durably integrated through ingestion.
10. **Minor:** normalized redirects were validated but the original request was followed.
11. **Proof gaps:** chunked/budget/headers/login/WebKit cancellation/subresource/decode/no-overwrite/warning/refetch cases were weak or absent.

The Task 5 pinned-resource packaging dependency remains separate and open. Default production extraction is still intentionally fail-closed; do not mark that integration accepted.

## Inputs

Read the “Fix round 1” section and corrected receipt discussion:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Review package:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-fix1-review-ee5b6b72..90e9d76f.diff`

- Base: `ee5b6b72`
- Head: `90e9d76f`

Read the package once. Do not run git commands, mutate the worktree, or crawl unrelated code.

Adversarially verify:

- navigation permits exactly one supplied main-frame document and blocks all other document/subresource/popup paths;
- every WebKit continuation has token/once-only cancellation and ignores late callbacks;
- URLSession delegate witnesses and mutable state are genuinely safe off Main Actor;
- configuration sanitization preserves injected protocol testability while removing all extra headers/state;
- normalized redirect request and counter logic cannot bypass limits;
- login dominance avoids both `/author` false positives and login-page false negatives;
- remaining total bytes cap each image request and stops future requests at exhaustion;
- complete bounded decode, MIME/type agreement, dimensions, no-overwrite publication, containment/symlink checks, and temp cleanup are sound;
- post-import warning/state persistence cannot break Task 3 retry/recovery identity, delete the wrong package, or make readable content failed;
- tests genuinely exercise the named cases and later snapshot load does not refetch;
- no new Critical/Important cancellation, data-loss, DoS, privacy, or Swift 6 isolation regression appears.

Treat reported execution as unverified during code review, but preserve its proof boundaries. The report claims repository-supported: build succeeded; URL 6/6; image 5/5; ingestion 14/14; WebKit policy 2/2. Earlier zero-test/install and simulator-host failures are excluded.

## Output

For each original finding, state `ADDRESSED`, `PARTIALLY ADDRESSED`, or `OPEN`, with file:line evidence. Identify any new Critical or Important breakage. Keep the Task 5 bundle dependency separately open.

End with exactly one:

- `Fix round: All code findings addressed, no new Critical/Important breakage; Task 5 integration remains`
- `Fix round: Findings remain`
