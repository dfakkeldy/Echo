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
