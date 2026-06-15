# Plan — Finish On-Device EPUB Narration

**Date:** 2026-06-15 · **Branch:** `claude/audit-phase7-api` · **Audit:** `CODE_AUDIT_NARRATION.md` (current-state, same date)

**Goal:** take narration from "built but blocked + device-unverified" to "works end-to-end on the iPhone 12 Pro (A14) and is ready for 1.0." The hard part is one P0 (audit §3.1); the rest is app-side and well-scoped.

**Execution model:** designed for `superpowers:subagent-driven-development` — each phase is an independent task with its own spec, TDD loop, and code-quality review, committed scoped (`git add <files>`, never `-A`, because concurrent automation also commits to this branch). Build with `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. Never construct a full `PlayerModel` in a unit test (iOS-26-sim isolated-deinit teardown crash) — use `DatabaseService(inMemory:)` + the `TTSEngine`/service seams.

---

## Phase 0 — Decisive on-device datapoint (GATE, no code) ⛔ do first

The crash logs predate the `613c577` revert, so **current HEAD (`KokoroAneManager()` = `.default` = `ane-tail-gpu`) has never been tested on-device since the revert.** Git says `.default` was the crashing config, so this is expected to still crash — but it's a 10-minute, zero-cost confirmation that decides Phase 1's branch.

- **Do:** Build + install current HEAD (`xcodebuild -scheme Echo -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates -jobs 4 build` → `devicectl device install`). Narrate a real, long chapter of the Alice EPUB.
- **Capture:** Console (`xclog`) for the load warnings ("Palette weight for Large stride convolution…", "FlexibleShapeInformation…") and any new `.ips` in `~/Library/Logs/DiagnosticReports`.
- **Decision:**
  - **Crashes (BNNS SIGTRAP)** → expected; proceed to **Phase 1A (model swap)**.
  - **Works** → the crash was a stale pre-revert artifact; skip Phase 1A, jump to Phase 2, and just remove the dead vocoder-routing comments. (Low probability — keep evidence either way.)

---

## Phase 1 — Resolve the P0 crash (§3.1) — *the crash decision*

**Root cause (settled):** A14 ANE rejects the Kokoro vocoder's palettized large-stride conv → CoreML CPU/BNNS fallback → uncatchable BNNS trap on long input. **Not** a routing bug — every FluidAudio compute-unit option is broken on A14 (BNNS=trap, GPU=invalid `anchor` shape). **The fix must change the model asset.**

### Recommended path — Phase 1A: swap to a fixed-shape, non-palettized Kokoro model

`mattmireles/kokoro-coreml` (MIT) is the only Kokoro asset with a **confirmed iPhone 12 Pro run** (static fp16 duration buckets 3/7/10/15/30 s, no dynamic ops, no `RangeDim`, no palettized large-stride conv; ~12.3 s for a 30 s clip via a staged decoder-pre-on-ANE / rest-on-CPU+GPU policy).

**Pre-work spikes (must pass before committing to 1A):**
1. **License gate** — confirm the model's G2P/phonemizer is permissive and **does not pull GPL espeak-ng** into the graph (the v1 hard constraint). If it does, either keep FluidAudio's Misaki frontend for G2P and feed phonemes to the new acoustic/vocoder models, or reject 1A.
2. **RAM gate** — the 4 GB A14 is the wall (MLX Kokoro OOMs on 30 s clips there). Confirm the fixed-shape CoreML buckets fit peak memory with `lookAhead=2`.
3. **Integration shape** — FluidAudio has **no model-revision override** (hard-resolves `FluidInference/kokoro-82m-coreml/ANE/`). Choose: **(a)** vendor the fixed-shape `.mlmodelc` into the app/Application-Support and write a thin CoreML runner *behind the existing `TTSEngine` seam*, bypassing `KokoroAneManager` for synthesis (cleanest — `KokoroTTSEngine` already isolates this); or **(b)** fork FluidAudio's `KokoroAneResourceDownloader`/model store to load the buckets. **Recommend (a):** the `TTSEngine` protocol already exists as the seam, so a `FixedShapeKokoroTTSEngine: TTSEngine` is a drop-in with no FluidAudio fork to maintain.

**Build (1A):** implement `FixedShapeKokoroTTSEngine` conforming to `TTSEngine` (G2P → acoustic → vocoder/tail via the static buckets; pick the smallest bucket ≥ utterance length; `prepare()` does the one-time compile). The `NarrationTextChunker` already bounds utterances to ≤200 chars, which maps to the small buckets — keep it (now it's load-bearing for bucket selection, not a crash workaround). Swap the engine at the single construction site (`KokoroTTSEngine()` injection on `PlayerModel`).

**Acceptance (1A):** a full real chapter narrates on the A14 with no crash; RTF and peak RAM recorded (feeds §7.3 + the `lookAhead` decision); audio intelligible.

### Fallback — Phase 1B: gate narration on A15+

Only if 1A fails a gate (license/RAM/quality) or proves too costly. Feature-flag Kokoro narration off for A14, surface "narration needs a newer device," keep the audio-less reader fully functional. **Cost: excludes the owner's own iPhone 12 Pro — interim only, not a 1.0 answer.** Detect via device model / ANE generation, not OS version.

> **Decision to confirm with the owner before execution:** commit the plan to **1A (model swap, A14 stays the target)** or **1B (A15 gate for v1, revisit A14 later)**. Recommendation: **1A**, contingent on the two gates passing — they're cheap to check first.

---

## Phase 2 — T5: voice switch breaks playback (§5.1, High, app-side)

- **Seam:** `PlayerModel+Narration.swift:38-46` (eviction) + `:22,120-123`; `NarrationCacheStore.staleVoiceFiles`.
- **Fix:** stop-before-evict / run-generation guard — do not delete the currently-playing file until the new voice's chapter 0 is playing (exclude it from `staleVoiceFiles`, or stop playback + clear `tracks` before eviction).
- **TDD:** `NarrationCacheStoreTests` — assert the active file is excluded from eviction; a coordinator-level test (extracted in Phase 5) that the playing file survives until replacement.
- **Acceptance:** switching voice mid-playback cross-fades to the new voice's render with no missing-file failure (device-verify after Phase 1).

---

## Phase 3 — Read-along Layer 2: track-scoped interpolation (§5.2, High)

- **Seam:** `AlignmentService.swift:340-359` + `findBracketingAnchors:425-446`; recalc entry `:190`.
- **Fix:** partition anchored blocks by track/chapter before bracketing; interpolate only within a track's own per-track-0-based axis; no-op for single-track books. Keep the `anchoredOnly` narration shield unchanged.
- **TDD:** new `AlignmentServiceTests` cases — two tracks with disjoint chapter ranges + anchors that previously bracketed across the boundary; assert no cross-axis `audio_start_time`. Existing single-track + `anchoredOnly` tests must stay green.
- **Acceptance:** MP3-folder + multi-m4b read-along highlights the correct block; single-m4b unchanged.

---

## Phase 4 — Owner design asks (A + B)

**4A — Play button starts narration (§8.1, Medium).** Seam: `TransportControlsView.swift:58` / `PlaybackController.play():123`. Branch the Play action: when `hasEPUB && tracks.isEmpty && !narrationPlaybackState.isRunning`, call `startNarrationPlayback` (default/last voice) instead of no-op. Acceptance: Play on a fresh audio-less book starts narration; normal audiobooks unaffected.

**4B — Resume keeps the full chapter queue (§5.3, Medium).** Seam: `NarrationChapterPlanner.resume:33-40` + `PlayerModel+Narration.swift:75-134`. Keep the full chapter set in the queue, start playback at the resume index via placeholder tracks for earlier chapters that render on seek-back (lower cost than render-all). TDD: `NarrationChapterPlannerTests` for full-set-with-start-index; coordinator test for seek-back render. Acceptance: reopening shows all chapters in the queue, playing at the resume point, seek-back works.

---

## Phase 5 — Pipeline testability + coverage (§9.1, Medium)

- **Problem:** the most intricate new code (look-ahead/backpressure/pause-aware/at-gap-exempt/resume loop in `PlayerModel+Narration.swift:17-148`) is untested because it lives on the untestable `PlayerModel`.
- **Fix:** extract the loop *policy* (decide: render next? wait? advance-at-gap? resume index?) into a pure object tested with `DatabaseService(inMemory:)` + a mock `TTSEngine`; keep the `PlayerModel` extension as thin glue. Fold §9.2 (`NarrationRenderPlanner`) into this extraction (use it or delete it).
- **Acceptance:** policy decisions covered by unit tests incl. the Phase 2 + 4B behaviors; `make test-only FILTER=EchoTests/Narration*` green.

---

## Phase 6 — Pre-1.0 hardening + quick wins

- **§6.1** Exclude `.synthesized` from `CloudKitSyncService.uploadAnchors` fetch (Medium; one-line + test on the predicate).
- **§7.1** Stream chunks to the `AudioFileWriting` sink instead of buffering a whole chapter's PCM (matters on 4 GB A14).
- **Quick wins §2.1–§2.5:** Logger-gate + divide-guard the RTF print; `static let` the ISO8601 formatter; guard `chunks.first!`; log eviction failures; delete/wire `NarrationRenderPlanner`.
- **§5.5** "No text to narrate" message.
- **§8.2** `VoicePickerView` selected-state styling + `.accessibilityAddTraits(.isSelected)`.

---

## Phase 7 — `.m4b` export with real chapters (§5.4, Medium — optional for 1.0)

Integrate Apache `swift-audio-marker` so `AudioMarkerStub` writes real `chpl`/Nero atoms + `stik`, or ship per-chapter-files-only for 1.0 and label it. Decide scope with the owner; per-chapter export already works.

---

## Phase 8 — Device re-verification matrix + doc sync (after Phase 1 unblocks)

On the iPhone 12 Pro, confirm (all currently device-UNVERIFIED, §11):
1. Real book narrates without crashing (Phase 1) — RTF + peak RAM + thermals recorded (§7.3).
2. Read-along follows the **narrated** chapter, front matter stays blank (Layer 1 + write-side).
3. EPUB-file import loads the real book (not the 3-sentence fallback).
4. Voice switch mid-playback works (Phase 2).
5. Resume shows the full queue at the right chapter (Phase 4B); Play starts narration (Phase 4A).
6. Stats "Done" exits (already fixed — confirm).

**Doc sync (CLAUDE.md mandate):** update `ARCHITECTURE.md` "On-Device Narration" (engine = fixed-shape vendored Kokoro, not FluidAudio/ANE chunking) + `README.md`/`CHANGELOG.md` once Phase 1 lands. Use the `doc-sync` skill.

---

## Dependency order

```
Phase 0 (gate)
   └─> Phase 1  (P0 — unblocks all device verification)
         ├─> Phase 2  (T5)            ─┐
         ├─> Phase 4  (design asks)    ├─> Phase 8 (device re-verify + docs)
         ├─> Phase 5  (pipeline tests) │
         └─> Phase 6  (hardening)     ─┘
Phase 3 (read-along Layer 2) — independent of Phase 1; can run in parallel
Phase 7 (m4b export) — independent; optional for 1.0
```

Phases 2–7 are code-complete-able and unit-testable **without** the device; only the *acceptance* steps and Phase 8 need the A14 (and thus Phase 1). Phase 3 has no dependency on the crash fix.
