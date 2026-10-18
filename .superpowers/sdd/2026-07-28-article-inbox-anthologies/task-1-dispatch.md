# Task 1 implementer dispatch

You are implementing Task 1, the trusted capture-envelope and vendored Readability foundation for Echo's Article Workshop.

Read this first — it is your requirements, with the exact values to use verbatim:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-1-brief.md`

Work only in:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`

Context and binding decisions:

- This is the first implementation task; it consumes no prior Article Workshop API.
- `Shared` and `EchoTests` are file-system-synchronized Xcode groups, so the task must not modify `Echo.xcodeproj/project.pbxproj`.
- The sibling Global Pronunciation worktree owns `EchoCore/Services/Narration/NarrationService.swift`, `NarrationFileNaming.swift`, `EchoTests/NarrationFileNamingTests.swift`, `Echo.xcodeproj/project.pbxproj`, and `ARCHITECTURE.md`. Do not modify or coordinate through those files.
- Preserve deployment floors iOS 18, macOS 15, watchOS 11, Swift 6 strict concurrency, and default Main Actor isolation.
- Keep serialized domain values `Sendable` and nonisolated as required by the brief.
- Mozilla Readability 0.6.0 is the only newly authorized third-party component. Do not add another dependency.
- Never introduce cookie, authorization, credential, form, history, script, frame, or active-embed fields.
- Use only authored synthetic fixtures; do not copy real private article content into the repository.
- Follow strict TDD: add the specified tests first, run and record the expected RED failure, then implement, run GREEN verification, and keep output evidence.
- Make no changes outside the files named in the brief. Preserve unrelated worktree and sibling state.

If requirements or dependencies are unclear, return `NEEDS_CONTEXT` before editing. Otherwise implement exactly the brief, commit with its specified Conventional Commit subject, and self-review.

Write the detailed report to:

`/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo/.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-1-report.md`

The report must include implementation details, files changed, self-review, exact RED and GREEN commands with relevant output, the vendor-pin verification result, and concerns. Return only the short status contract: status, commit SHA/subject, one-line test summary, concerns, and report path.
