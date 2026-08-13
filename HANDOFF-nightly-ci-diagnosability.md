# Handoff — nightly CI diagnosability / PR #550 red

## 2026-08-13 — CI diagnosability fix pushed; root cause still unproven

Done:
- PR #550 (`nightly`→`weekly`) went red when #551 merged and advanced its head to
  `b0f8a500`. One failing test: `PlayerModelAccentTests.testUIColorSchemeDefaultsToLightAndIsSettable`.
- Established it is NOT a value regression: `uiColorScheme` is a stored property
  defaulting to `.light` (`EchoCore/ViewModels/PlayerModel.swift:346`) with no
  reachable writer, so the assertion is a tautology unless the process died.
- `b0f8a500` is the first commit ever to combine #545 and #551. #545's two nightly
  runs were CANCELLED (never validated); it failed its own branch twice and went
  green on `49d0d636`, a one-line spin-wait.
- Leading hypothesis: #545 added the only 4 `isolated deinit`s in EchoTests, all on
  `@MainActor final class` fixtures, against the project rule at
  `SleepTimerManager.swift:24`. Prior crash of this same class was ASan-root-caused
  (`81e4b73f`) to `swift_task_deinitOnExecutorMainActorBackDeploy`. NOT PROVEN —
  that commit reports ASan clean on 26.4/26.5 and this run used 26.5.
- Pushed PR #554 (ci.yml only): drop `-quiet` on the test step, add
  `-resultBundlePath` + failure artifact, log simulator runtime and Xcode version.
- Re-run of the identical commit (run 31709742124 attempt 2) was still in flight.

Next:
- Read the re-run verdict. Green ⇒ intermittent, #550 mergeable, instability stays
  open. Red ⇒ merge #554 first, then the next failure yields a crash trace.
- Do NOT blind-convert the 4 `isolated deinit`s: `MainActor.assumeIsolated` traps if
  the fixture is released off-main, so it needs the trace or a local repro first.
- Local repro blocked all afternoon: build slot contention (a 4h hung
  `ns-marks-the-spot` build, then the SchemaV41 session).

Resume:
```
Worktree: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/youtube-video-echo-relevance-b6ffe6
Branch:   fix/nightly-playermodel-accent-flake (PR #554 -> nightly)
Next:     gh run view 31709742124 --json status,conclusion   # re-run verdict for PR #550
```

## 2026-08-13 — LOCAL REPRO NEGATIVE: b0f8a500 passes the full suite

Done:
- Ran the full EchoTests suite locally on the exact failing commit b0f8a500:
  `** TEST EXECUTE SUCCEEDED **`. `testUIColorSchemeDefaultsToLightAndIsSettable`
  passed in 0.003s; all 6 PlayerModelAccentTests passed.
- Local Xcode is 26.6 (17F113) — IDENTICAL to CI's. Only the simulator device
  differs (local "iPhone 17"; CI "iPhone 17 Pro Max", OS 26.5).
- Conclusion: not a logic regression. Same toolchain + same commit passes locally
  and failed once on CI ⇒ CI-environment-specific, intermittent, process-level.
  Consistent with this class's documented crash history (81e4b73f), whose three
  mitigations (CI skip, 26.1 OS pin, no `-quiet`) have ALL since been removed.
- The re-run of 31709742124 never returned a verdict: #552 merged to nightly at
  18:02 (a9ef3a80), moving #550's head and cancelling it via `cancel-in-progress`.
- Verified #552 does NOT arm the weekly macOS hard-fail I had warned about — it
  downgrades that to a warning on every channel.

Next:
- Await run 31728709208 (#550 @ a9ef3a80) and 31727119980 (#554, first run with
  `-quiet` off + result bundle). #554's run is the one that yields a crash trace.
- If it fails again on the same test, the precedented unblock is 81e4b73f's own
  remedy: skip PlayerModelAccentTests on CI (the crash cannot affect production —
  the app keeps ONE PlayerModel for its lifetime; only tests deallocate one).
- Still do NOT blind-convert the 4 `isolated deinit`s (assumeIsolated traps off-main).

Resume:
```
Worktree: /Users/dfakkeldy/Developer/Echo/.claude/worktrees/youtube-video-echo-relevance-b6ffe6
Branch:   fix/nightly-playermodel-accent-flake (PR #554 -> nightly)
Next:     gh run view 31727119980 --json status,conclusion   # PR #554: trace-capable run
```
