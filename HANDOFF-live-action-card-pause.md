# HANDOFF — watch Now Playing card shows ⏸ while paused

## 2026-08-15 — root cause found, fix written, NOT yet compiled

Done:
- Worktree was branched off `main`, 614 commits behind. Reset to `origin/nightly` (`006ab42a`) before any edits.
- Identified the card: it is the **system watchOS Now Playing card**, not Echo's widget. Echo's
  `Echo WidgetExtension` is watchOS-only and its two accessory views draw no transport button;
  `Echo_WidgetControl` is `#if !os(watchOS)` inside that watchOS-only target, so it ships nowhere.
  Confirmed by the reporter: the iPhone Lock Screen was wrong too.
- Root cause: `NowPlayingController.swift` gated `center.playbackState` behind `#if os(macOS)`.
  `MPNowPlayingInfoCenter.h` says the property applies "where playback state cannot be determined by
  the application's audio session" and is `ios(13.0)`-available. Echo meets that condition on iOS:
  `AudioEngine.pause()` pauses only the `AVAudioPlayerNode`, the `AVAudioEngine` keeps running, and
  the `.playback` session is never deactivated — so rate-0 metadata was the only pause signal.
- Fixed `NowPlayingController.updateNowPlayingInfo` (publish `playbackState` on every platform
  EchoCore builds for) and `PlayerModel.stopVoiceMemo` (guard an unconditional resume+publish that
  produced the same divergence). Added `playbackStateFollowsPauseFlagOnEveryPlatform` regression test.
- Verified EchoCore builds only into `Echo` (iOS), `Echo macOS`, `echo-cli` — never watchOS — so the
  ungated property is compile-safe.

Next:
- Compile + run tests. Blocked 2026-08-15 16:39: slot `--status` = HOLD, outside windows AND
  pressure=2 (max 2), swapFree 1452MB < 2048MB warnMin. `XBG_ALLOW_NOW=1` does NOT override pressure.
- Then device-verify on paired iPhone + Watch: pause from phone, pause from watch, at 2× speed, and
  after a phone-call interruption. Confirm the Lock Screen still behaves (guards `3efb2c63`).
- Open PR against `nightly`.

Deliberately NOT done:
- `AudioEngine.pause()` does not pause the `AVAudioEngine`. Pausing it would make the session state
  self-evident to the system, but `DefaultSoundscapeMixer` / `DefaultChimePlayer` attach to the same
  engine, so ambient soundscape would go silent while paused. User-visible; needs a decision.
- `PlaybackController.stop()` never republishes Now Playing. Verified it cannot cause this symptom
  (both live callers republish right after). The naive one-liner would publish a
  "No track selected" card, so it needs design thought, not a reflex fix.

Resume:
```
Worktree /Users/dfakkeldy/Developer/Echo/.claude/worktrees/echo-narration-test-426822,
branch claude/live-action-card-pause-0ed991 (based on origin/nightly 006ab42a).
Next action: /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh --status, and when it reports FREE+admit,
run: /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```
