# Handoff — macOS Echo UX (progress, alignment badge, hideable pane)

## 2026-08-15 — implementation and tests written, build pending

Done: three macOS complaints addressed. (1) `MacAlignmentService.align` gained
an `onProgress` callback with real per-chunk transcription progress and
indeterminate phases; `MacBatchProcessingService` forwards it (the old hardcoded
0.33/0.66 jumps fired before a multi-hour await), exposes an in-memory
`Activity`, and a new `MacBatchActivityStrip` keeps it visible in the main
window. (2) New `EchoCore/Services/BookAlignmentSummary.swift` + `MacAlignmentBadge`
in the reader header separate a real alignment from the importer's word-count
estimate. (3) `MacTriPaneView` is now a two-column split view plus a real
`.inspector` — a three-column `NavigationSplitView` has no visibility value that
hides the detail column, which is why ⌘T hid the wrong panes. Tests:
`BookAlignmentSummaryTests` (real unit tests) and `MacAlignmentVisibilityTests`
(source-scanning; all 48 assertions pre-verified against normalized source).

Next: build the macOS scheme, `make build-tests` + `make test`, and `make echo-cli`
(BookAlignmentSummary auto-joins all three targets). Then commit, push, PR to
`nightly`, and delete this file in that PR.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-echo-ux-c62409,
branch claude/macos-echo-ux-c62409. Build the "Echo macOS" scheme through
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh, then make build-tests and
make test-only FILTER=EchoTests/BookAlignmentSummaryTests, then make echo-cli.
```

## 2026-08-16 — PR #573 open against nightly

Done: macOS scheme builds; `make build-tests` succeeds; both new suites pass
(34 tests). Isolation fix committed (`nonisolated struct BookAlignmentSummary` —
`Sendable` alone does not opt out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
Branch pushed, PR https://github.com/dfakkeldy/Echo/pull/573.

Next: local `make echo-cli` is queued behind another session's build (CI gates it
too, as its last step). Watch CI on #573, then delete this handoff file in a final
commit on the same PR.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/macos-echo-ux-c62409,
branch claude/macos-echo-ux-c62409. Check `gh pr checks 573`; if green, git rm
HANDOFF-macos-echo-ux.md, commit, push.
```
