# HANDOFF — abs-stub-scope-isolation

## 2026-08-16 — race confirmed, fix written, standalone-verified

Done:
- Confirmed the shared-scope race with a standalone SwiftPM probe compiling the
  REAL `URLProtocolStub.swift`: 4 @MainActor suites (one `.serialized`) all
  overlap, 50/50 runs fail before, 0/50 after.
- Found a 5th participant the brief did not list: `ABSImportServiceTests` writes
  the shared scope (`reset()` + `makeSession()` + 8 stubs) without reading it.
- Migrated all five suites to per-test `*Fixture` classes with UUID scopes,
  matching `AudiobookshelfServiceDownloadFixture`.
- Deleted the default-scope API from `URLProtocolStub` so the footgun is now a
  compile error; added `EchoTests/URLProtocolStubScopeTests.swift`.

Next:
- Real-target verify: `make build-tests` then `make test-only` on the 6 suites.
  Build slot opens 22:00. This also settles whether xcodebuild's
  `-parallel-testing-enabled NO` reaches Swift Testing's in-process scheduler —
  the one thing the standalone probe cannot show.
- Then open the PR with `--base nightly`.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/busy-gauss-3c559c,
branch test/abs-stub-scope-isolation. Run
`/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests`, then
test-only on EchoTests/URLProtocolStubScopeTests and the 5 ABS suites, then
`gh pr create --base nightly`.
```
