# Task 7 specification fix round 1

Resume Task 7 in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Current head:

`735ba1e0`

Fix only the confirmed Minor specification omission:

- Duplicate warning evidence must include exact stored `sourceURL` equality in addition to canonical URL and content digest.
- A different capture with the same source URL, absent/different canonical URL, and different digest must still produce the nonblocking possible-duplicate warning.
- Keep Both must remain available. Do not merge, delete, refetch, or canonicalize beyond the stored evidence.
- Exclude the item itself by ID and preserve deterministic ordering.

Add the focused regression first and obtain a valid RED receipt. Keep the production change in the existing Task 7 service boundary; do not modify the project, DAO/schema, share extension, Task 6 classifier, narration, architecture, or UI unless compilation strictly requires it.

Verify:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
make test-only FILTER=EchoTests/LibraryViewModelTests
git diff --check
```

Commit:

`fix: include source URL duplicate evidence`

Append “Specification fix round 1” with RED/GREEN receipts to `task-7-report.md`. Return only when committed and clean.
