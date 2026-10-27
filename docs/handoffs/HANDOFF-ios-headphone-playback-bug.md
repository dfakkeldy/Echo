# Handoff — iOS headphone-connect playback bug

## 2026-08-15 — Root cause found, fix written, build gate pending

Done:

- Repro report: connecting headphones mid-book stopped playback, the transport
  kept showing a pause button, and resuming took two taps.
- Root cause: `AVAudioEngine` stops itself on a hardware reconfiguration and
  posts `AVAudioEngineConfigurationChange`. Nothing observed it. The existing
  route observer only handles `.oldDeviceUnavailable` (device *leaving*), so
  `isPlaying` stayed true over a stopped engine — hence the stale pause button,
  and the first tap only `pause()`d an already-stopped engine.
- Fix in `EchoCore/Services/AudioEngine.swift`: observe the notification per
  engine instance, and on a reconfiguration mid-playback re-seek to
  `currentTime` so audio follows the new route. The re-seek is required — the
  stop resets the player node's sample time that `currentTime` derives from, so
  a bare `engine.start()` would rewind to the last seek point. Landing back on
  the built-in output is treated as a stop, not a route to follow, so the
  disconnect path never blasts audio out loud. New
  `audioEngineDidStopUnexpectedly` delegate hook drives a real pause when the
  engine cannot be restarted.
- 5 tests in `EchoTests/AudioEngineConfigurationChangeTests.swift`.
  `swiftc -parse` clean; not yet compiled or run.

Next:

- `make build-tests` then `make test-only FILTER=EchoTests/AudioEngineConfigurationChangeTests`.
  The build slot was owned by the `live-stock-evidence` worktree's `make test`.
- Device acceptance is separate: connect Bluetooth headphones mid-book and
  confirm audio continues on the new route with no double-tap.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/busy-gauss-3c559c,
branch claude/ios-headphone-playback-bug-733213. Run
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests, then
make test-only FILTER=EchoTests/AudioEngineConfigurationChangeTests.
```

## 2026-08-16 — Local gates green, unpushed

Done:

- All four targets that compile `AudioEngine.swift` build clean: Echo (iOS),
  Echo macOS, Echo Watch App, echo-cli (Release). Only pre-existing warnings.
  The iOS scheme alone would not have caught a break in the latter three.
- `make test-only FILTER=EchoTests` — 3824 tests in 538 suites passed in
  1573s. AudioEngineConfigurationChangeTests 5/5, PlaybackControllerTests
  21/21.

Next:

- Push and open a PR against `nightly` (not yet done — awaiting the go-ahead).
- Device acceptance, still unproven and not provable locally: connect
  Bluetooth headphones mid-book and confirm audio continues on the new route
  with no double-tap; then unplug and confirm pause-on-disconnect still holds,
  which is the path the built-in-output guard protects.

Resume:

```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/busy-gauss-3c559c,
branch claude/ios-headphone-playback-bug-733213, commit 1b8eae2f, local gates
green. Next action: git push -u origin HEAD and gh pr create --base nightly.
```
