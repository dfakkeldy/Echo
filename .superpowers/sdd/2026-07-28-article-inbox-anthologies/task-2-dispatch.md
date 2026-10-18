# Task 2 implementer dispatch

You are implementing Task 2, the GRDB persistence foundation for Article Workshop captures, revisions, anthology projects, entries, and build receipts.

Read this first — it is your requirements, with the exact values to use verbatim:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-brief.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Context and binding decisions:

- Task 1 is complete. Consume `ArticleCaptureMethod` from `Shared/ArticleCapture/ArticleCaptureEnvelope.swift`; do not duplicate it.
- Live `origin/nightly` remains at `33c17fda`, and V37 is free. Use `v37_article_workshop` exactly as the brief states.
- Follow the existing `DatabaseService`, migration, record, DAO, and test-fixture patterns in Echo. Keep user-data migrations additive and transactional through GRDB's migrator.
- Preserve all exact table names, column names, constraints, unique keys, foreign-key delete policies, indexes, and DAO signatures in the brief.
- `anthology_entry.capture_id` must restrict deletion. Stable slots are monotonic per anthology and are allocated with the `next_stable_slot` update in the same transaction.
- Never use `INSERT OR REPLACE` or GRDB `.replace` for records with dependent rows; it performs delete-then-insert and can fire cascades. Use the existing safe insert/update/upsert patterns appropriate to each exact DAO behavior.
- Do not swallow database or Codable errors. Parameterize data-bearing SQL.
- Preserve deployment floors iOS 18, macOS 15, watchOS 11; Swift 6 strict concurrency; and default Main Actor isolation. Database work must not create UI-thread-only APIs.
- `Shared` and `EchoTests` are file-system-synchronized groups. Do not modify `Echo.xcodeproj/project.pbxproj`.
- The Global Pronunciation sibling owns the listed narration files, the project file, and `ARCHITECTURE.md`; do not modify them.
- Follow strict TDD: write the migration and DAO lifecycle tests first, record expected RED output, then implement minimal production code and record GREEN evidence.
- Make no changes outside the files named in the brief. Preserve unrelated worktree and sibling state.

If requirements or an existing database pattern conflict with the brief, return `NEEDS_CONTEXT` before editing. Otherwise implement exactly the brief, commit with its specified subject, and self-review migration safety, cascades, stable-slot monotonicity, ordering, and failed-build behavior.

Write the detailed report to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-2-report.md`

The report must include implementation details, files changed, self-review, exact RED and GREEN commands with relevant output, and concerns. Return only the short status contract: status, commit SHA/subject, one-line test summary, concerns, and report path.
