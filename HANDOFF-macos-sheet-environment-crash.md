# Handoff — macOS App-level sheet environment crash

## 2026-08-13 — Fix committed, awaiting macOS build verification

Done: Diagnosed the View ▸ Article Workshop… crash (`EXC_BREAKPOINT` in
`EnvironmentBox.update`). Cause is modifier ordering in `Echo_macOSApp.swift`:
all six `.environment(...)` writes are applied to `MacTriPaneView()` and the
`.sheet` modifiers are chained *after* them, so every sheet captures the bare
scene-root environment. Proved with a standalone SwiftUI harness (`swiftc`, no
xcodebuild): the shape traps, and passes via init-injection, in-closure
re-injection, or moving `.environment` outside `.sheet`. Three more sheets had
the same latent crash (Anki export → `DatabaseService`; .m4b and slideshow
exports → `SettingsManager`). All four now use constructor injection; commit
`384948f3`. Added `EchoTests/MacSheetEnvironmentInjectionTests.swift` +
`MacSheetScan.swift`; the scanner was verified against real sources with a
standalone harness, including a negative control proving the pre-fix shape
fails it.

Next: Build the `Echo macOS` scheme (blocked earlier — another session held the
build slot with an `ns-marks-the-spot` run), then `make build-tests` +
`make test-only FILTER=EchoTests/MacSheetEnvironmentInjectionTests`. Then PR to
`nightly`. Device check: open each of the four sheets on the real Mac app.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/peaceful-jones-5c018f,
branch claude/peaceful-jones-5c018f. Verify commit 384948f3: run
`/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 CODE_SIGNING_ALLOWED=NO`,
then make build-tests && make test-only FILTER=EchoTests/MacSheetEnvironmentInjectionTests,
then open a PR with --base nightly.
```

## 2026-08-13 — Local verification green, PR opened

Done: `Echo macOS` scheme BUILD SUCCEEDED (the four converted views compile, which
also proves no other call site presented them). `make build-tests` → TEST BUILD
SUCCEEDED; `make test-only FILTER=EchoTests/MacSheetEnvironmentInjectionTests` →
4/4 passed. CHANGELOG `[Unreleased] ▸ Fixed` entry added (`436bee1d`). Pushed and
opened a PR against `nightly`.

Next: Watch hosted CI ("Build gate + tests", ~53 min for a full pass — a ~8 min
"failure" died at the build step). Then device-verify: open View ▸ Article
Workshop…, Study ▸ Export for Anki… (⌥⌘E), .m4b export, and slideshow export in
the real Mac app. Delete this file in the PR that closes the task.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/peaceful-jones-5c018f,
branch claude/peaceful-jones-5c018f, PR open against nightly. Run
`gh pr checks --watch` and report CI as passing, failing, pending, or blocked.
```
