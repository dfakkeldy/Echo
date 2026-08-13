# Task 6 fix round 5 review

Review the final Task 6 authentication-classification delta in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Read:

- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-fix5-review-package.md`
- `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-6-report.md`

Review range:

- base: `e1120e9d`
- head: `daf7e4ea`

Adjudicate the one remaining Important finding:

1. `action="/auth"` is recognized as authentication-required when the form also has a password input.
2. Arbitrary form/control attributes such as `class="login-demo"` cannot independently supply login semantics.
3. Nested visible button text such as `<button><span>Log in</span></button>` is normalized and recognized.
4. A generic update-password form remains capturable.
5. Authentication still requires a password input plus an independent semantic signal from the bounded accepted sources.

Inspect the actual code and tests. Check for catastrophic/unbounded regex behavior, entity or tag-stripping mistakes that reverse the security result, and any regression in the immediate outside-heading fallback. Do not broaden into previously accepted Task 6 areas unless this delta demonstrably breaks them. Treat the build and focused suite counts as implementer receipts rather than rerunning Xcode.

Return exactly:

- finding-by-finding `ADDRESSED`, `PARTIALLY ADDRESSED`, or `NOT ADDRESSED` with file/line evidence;
- any new Critical or Important issue introduced by this delta;
- `Fix round: All findings addressed, no new Critical/Important breakage` only if fully clean, otherwise `Fix round: Findings remain`.
