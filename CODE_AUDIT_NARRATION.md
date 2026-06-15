# Narration Feature — Code Audit (current state)

**Re-audited:** 2026-06-15 · **Branch:** `claude/audit-phase7-api` · **Method:** read-only. Background upstream research (FluidAudio releases/issues + HuggingFace model variants) + git archaeology of the engine config + symbolicated crash logs (`/tmp/echo-crash2/*.ips`, via `xcsym`) + 3 focused code-reading passes over the current root tree. Every High/Critical was personally re-verified against the cited lines.

**Scope:** `EchoCore/Services/Narration/*`, `EchoCore/ViewModels/PlayerModel+Narration.swift`, `EchoCore/Views/Narration/*` + the narration entry points in `NowPlayingTab` / `TransportControlsView` / `PlaybackController`, `AlignmentService.recalculateTimeline` (read-along), `CloudKitSyncService.uploadAnchors` (sync leak), and the narration test suites. **Excluded:** `.claude/worktrees/*` (scratch copies from concurrent automation) and `build/` (dependency checkouts).

> **This supersedes the PR #61-era audit.** That audit captured a non-functional spike. Since then the engine became real (FluidAudio/Kokoro), narration was rewired through the main `PlayerModel` pipeline, `BookDetailViewModel`/`MisakiPhonemizer`/`ModelDownloader` were deleted, and most prior High/Medium findings were resolved. **Appendix A** maps every prior §-reference to its current disposition so external references (memory, commit messages) still resolve.

**Verdict in one line:** The narration stack is now genuinely built and largely sound — but it is **blocked by a single P0: an A14-hardware-specific crash in the Kokoro vocoder that no FluidAudio configuration can fix (§3.1).** Until that is resolved by a model-asset change, the feature cannot be end-to-end device-verified, and everything else in this audit (all device-unverified) is downstream of it.

---

## 1. Executive summary

1. **[Critical] Kokoro vocoder traps on A14 for real-book-length input — the P0 blocker** — uncatchable `EXC_BREAKPOINT`/SIGTRAP in `libBNNS` `BNNSGraphContextExecute_v2`; A14-ANE-specific, **not** a routing bug, **not** fixable by any FluidAudio compute-unit config — §3.1 — `KokoroTTSEngine.swift:6,28`.
2. **[High] T5 voice-switch deletes the currently-playing file before stopping playback** — `startNarrationPlayback` evicts stale-voice files synchronously at the top, before the AVPlayer pointed at one of them is stopped — §5.1 — `PlayerModel+Narration.swift:38-46`.
3. **[High] Read-along "Layer 2": `recalculateTimeline` interpolates across track boundaries** — corrupts `audio_start_time` for MP3-folder / multi-m4b books; narration is shielded by `anchoredOnly`, the general case is not — §5.2 — `AlignmentService.swift:340-359,425-446`.
4. **[Medium] Resume is forward-only → only the resumed chapter is queued** (owner design ask B) — `NarrationChapterPlanner.resume` slices the plan and the render loop only ever queues that slice — §5.3 — `PlayerModel+Narration.swift:75-134`, `NarrationChapterPlanner.swift:33-40`.
5. **[Medium] The Play button no-ops for an un-started narration book** (owner design ask A) — `PlaybackController.play()` early-returns on `tracks.isEmpty`; narration is only startable via the "Listen" nudge — §8.1 — `PlaybackController.swift:123`, `TransportControlsView.swift:58`.
6. **[Medium] The entire `startNarrationPlayback` pipeline has zero test coverage** — backpressure, book-switch guards, resume, at-gap advance, and error paths are all untested; the old `BookDetailViewModel` tests were deleted with it — §9.1.
7. **[Medium] Synthesized TTS anchors are not excluded from the public CloudKit upload** — `uploadAnchors` fetches all anchors with no source filter; an audio-less narrated book would push pure `.synthesized` (device-specific) anchors to the community payload — §6.1 — `CloudKitSyncService.swift:82-89`.
8. **[Medium] `.m4b` export still writes no chapter atoms** — `AudioMarkerStub` copies the file only; per-chapter export works, m4b authoring does not — §5.4 — `AudioMarkerStub.swift:10-19`.
9. **[Medium] Everything except the lossless-audio fix is device-UNVERIFIED** — code-complete + unit-tested but blocked from end-to-end device testing by §3.1; treat read-along-follows-chapter, EPUB-file import, and resume as unproven on device — §11.
10. **[Medium] Perf unknowns for the A14 target** — whole-chapter PCM buffering is now ✅ fixed via stream-to-sink (§7.1); the remaining unknown is real on-device RTF/thermal measurement to size the streaming cushion (§7.3).

**Severity distribution:** 1 Critical (the blocker), 2 High, ~12 Medium, ~10 Low. The Critical is upstream/hardware; the two Highs are app-side and fixable.

---

## 2. Quick wins (≤30 min each)

- **§2.1** Route the per-synthesis RTF `print()` through `Logger` (the file doesn't import `os.log` yet) and guard the `duration / inferenceTime` divide against a zero denominator — `KokoroTTSEngine.swift:34-36`. **Severity: Low.**
- **§2.2** Hoist the per-call `ISO8601DateFormatter()` to a `static let` (codebase convention — `AlignmentService`, `EPubBlockDAO`) — `NarrationService.swift:51`. **Severity: Low.**
- **§2.3** Delete the dead `NarrationRenderPlanner` (its `nextChapterToRender` has zero callers; render-ahead is implemented inline) or wire it in — `NarrationRenderPlanner.swift:5-42`. **Severity: Low.**
- **§2.4** Guard the `chunks.first!` force-unwrap with the same `!chunks.isEmpty` invariant the caller relies on — `AVFoundationAudioWriter.swift:24`. **Severity: Low.**
- **§2.5** Log (don't `try?`-swallow) stale-voice eviction failures so an undeletable file doesn't silently grow the store — `PlayerModel+Narration.swift:43-45`. **Severity: Low.**

---

## 3. Concurrency & runtime stability

### 3.1 Kokoro vocoder traps on A14 for real-book-length input (THE P0 BLOCKER)
- **Location:** `KokoroTTSEngine.swift:6,28` (`KokoroAneManager()` → `manager.synthesizeDetailed`); crash is entirely inside `libBNNS.dylib`.
- **What:** Synthesizing a real book paragraph on the iPhone 12 Pro (A14, iOS 26.5) traps with an uncatchable `EXC_BREAKPOINT`/SIGTRAP. `xcsym` shows the triggered thread (`com.apple.e5rt.concurrentExecutionQueue`) is 100% inside `BNNSGraphContextExecute_v2` ← `E5RT::Ops::BnnsCpuInferenceOperation::ExecuteSync()` — zero Echo frames. Short content synthesizes fine; long input crashes.
- **Root cause (verified):** On A14 the ANE compiler rejects the Kokoro vocoder's palettized large-stride convolution (load warning: *"Palette weight for Large stride convolution is not supported"*). CoreML falls that op back to CPU/BNNS, and BNNS traps on the large dynamic tensor shape that long input (high acoustic-frame count `T_a`) produces. It is a **trap, not a Swift throw** — uncatchable, only preventable. **It is NOT a compute-unit routing bug:** FluidAudio 0.15.3 already ships the per-stage `ane-tail-gpu` split as `KokoroAneComputeUnits.default`, and the no-arg `KokoroAneManager()` resolves to exactly that (`KokoroAneManager.swift:47`). Git proves `.default` was the crashing config: commits `69c4a71`→`c0e6e98`→`153d3c4` all ran `KokoroAneManager()`, and **both crash logs were captured while that build was live**; the subsequent vocoder→GPU experiment (`d3a4a99`) failed differently (*"Invalid shape for output feature 'anchor'"* — the vocoder's `anchor` output is a deliberate ANE graph-anchor, invalid off-ANE) and was reverted (`613c577`). Char-chunking (`NarrationTextChunker`, ≤200 chars) cannot help because the bad shape is driven by `T_a`, not character count.
- **Why:** This is the gate on the entire feature. Until it's resolved, no real book can be narrated on the A14 target, and nothing downstream can be device-verified.
- **Action:** **Change the model asset, not the routing** (see the plan's Phase 1). The only Kokoro path with a confirmed iPhone 12 Pro run is the fixed-shape, non-palettized `mattmireles/kokoro-coreml` (static fp16 duration buckets, no dynamic ops, no palettized large-stride conv). FluidAudio exposes no model-revision override, so adopt it by vendoring the fixed-shape `.mlmodelc` behind the existing `TTSEngine` seam (thin CoreML runner) or forking FluidAudio's resource resolver. Run one decisive on-device test of current HEAD first (predicted: still crashes). Fallback: gate narration on A15+ (excludes the A14 target — interim only).
- **Severity: Critical** (confirmed; upstream/hardware).

> **Resolved since the prior audit:** §3.1-cancel (render task is now stored + cancelled in `startNarrationPlayback` and on book-switch — `PlayerModel+Narration.swift:22,52`), §3.2-main-actor (AAC encode is now off-main and the track+anchors write is one `await db.write` transaction — `NarrationService.swift:115-119`, `AVFoundationAudioWriter`), §3.3/§3.4 (Misaki + ModelDownloader deleted — FluidAudio owns G2P + download). See Appendix A.

### 3.2 Stale-voice eviction swallows errors
- **Location:** `PlayerModel+Narration.swift:43-45`.
- **What:** `try?` discards any failure from deleting a stale-voice file. Unlikely to fail in practice, but a persistently-undeletable file grows the store unbounded across voice changes with no signal.
- **Action:** Log the failure. (Distinct from §5.1, which is the *correctness* bug of evicting the playing file.)
- **Severity: Low.**

---

## 4. API modernity

_No findings._ No deprecated or about-to-be-removed APIs in the current narration slice. The relevant modernity lever remains raising `SWIFT_STRICT_CONCURRENCY` to `targeted` for the module (§10) so cross-actor issues surface at compile time before the Swift-6 migration.

---

## 5. Bugs / logic errors

### 5.1 Voice switch evicts the currently-playing file before stopping playback
- **Location:** `PlayerModel+Narration.swift:38-46` (eviction) vs `:52,107,120-123` (render/replace).
- **What:** `startNarrationPlayback` is the voice-switch entry point (`VoicePickerView.swift:41` calls it with the new voice). It cancels the render task (`:22`) and then, **synchronously at the top (`:38-46`), deletes every file whose voice ≠ the new voice** — including the old-voice chapter file the `AVPlayer` is currently playing — long before any `prepareToPlay`/track replacement happens. The playing file is pulled out from under the player.
- **Why:** Switching voice mid-playback breaks the current playback (missing-file / decode failure) instead of cleanly cross-fading to the new voice's render. This is the known "T5" bug.
- **Action:** Add a run-generation guard or stop-before-evict: stop playback and clear `tracks` before eviction, or exclude the currently-playing file from `staleVoiceFiles` and evict it only after the new chapter 0 is playing. Cover with a unit test on `NarrationCacheStore.staleVoiceFiles` + a pipeline test that asserts the playing file survives until replacement.
- **Severity: High** (confirmed).

### 5.2 `recalculateTimeline` interpolates across track boundaries ("read-along Layer 2")
- **Location:** `AlignmentService.swift:340-359` (bracketing interpolation) + `:425-446` (`findBracketingAnchors`); the recalc entry is `:190`.
- **What:** When `anchoredOnly == false` (the default for real audiobooks), `findBracketingAnchors` searches the **whole-book** anchored-block list by `sequenceIndex`, ignoring track boundaries. For a multi-file book each track reports per-track 0-based time, so interpolating a block in track N using a bracketing anchor in track N-1 mixes two different time axes and writes a nonsensical `audio_start_time` (negative → clamped to the `-1` sentinel and dropped, or a large positive → wrong-chapter highlight). The reader reads `timeline_item WHERE audio_start_time >= 0` (`ReaderFeedViewModel`), and for multi-m4b the `ReaderActiveBlockResolver` track-scope is *disabled*, so the corruption surfaces directly.
- **Why:** Read-along highlights the wrong block or nothing for **MP3-folder and multi-m4b** books. Single-m4b / single-file are unaffected (one axis). **Narration is shielded** because `renderChapter` calls `recalculateTimeline(anchoredOnly: true)` (`NarrationService.swift:134-135`), which skips synthetic boundaries + interpolation — but that masks rather than fixes the general bug.
- **Action:** Make interpolation track-scoped: partition anchored blocks by track/chapter before bracketing, and only interpolate within a track's own axis. No-op for single-track books. Add multi-file `AlignmentServiceTests` (the suite currently has only single-track interpolation + `anchoredOnly` cases).
- **Severity: High** (real user-facing read-along corruption for multi-file books; pre-existing, surfaced by narration work).

### 5.3 Resume queues only the resumed chapter (owner design ask B)
- **Location:** `NarrationChapterPlanner.swift:33-40` (`resume` returns `Array(chapters[pos...])`), consumed at `PlayerModel+Narration.swift:75-84,90-134`.
- **What:** On reopen, `resume` drops every chapter before the resume index, and the render loop only ever iterates / queues that forward slice (`tracks = [track]` at offset 0, append after). So the queue contains only the resumed chapter onward — the user can't scrub back to earlier chapters from the Now Playing queue.
- **Action:** Keep the full chapter set in the queue but start playback at the resume index — e.g. inject lightweight placeholder tracks for earlier chapters that render on demand when seeked back, or render-all-but-seek. Decide the queue model in the plan (placeholder-on-seek is the lower-cost path). Cite: this is a queue-shape change, not a planner bug.
- **Severity: Medium** (UX; owner-requested).

### 5.4 `.m4b` export writes no chapter atoms
- **Location:** `AudioMarkerStub.swift:10-19` (caller `NarrationExportService.swift`).
- **What:** `writeChapters` does `removeItem` + `copyItem` only — no `chpl`/Nero atoms, no `stik`. Per-chapter file export is real; the single-file `.m4b` is a chapterless `.m4a` renamed. The comment is now honest ("simulates"), so this is a *capability gap*, not a false claim.
- **Action:** Integrate a real atom writer (Apache `swift-audio-marker`) before advertising `.m4b` export, or ship per-chapter-files-only for v1 and label it.
- **Severity: Medium.**

### 5.5 No user-visible message when a book has no narratable text
- **Location:** `PlayerModel+Narration.swift:63-70`.
- **What:** If the plan is empty, the code clears the "Preparing narration…" subtitle and returns silently. A user who tapped "Listen" sees nothing happen and no explanation.
- **Action:** Surface a brief "No text to narrate" state.
- **Severity: Low.**

---

## 6. Security

### 6.1 Synthesized anchors are not excluded from the public CloudKit upload
- **Location:** `CloudKitSyncService.swift:82-89` (fetch) + `:53-59` (`sourceRank`); writes at `NarrationService.swift:82-89`.
- **What:** `uploadAnchors` fetches **all** anchors for an audiobook with no source filter and pushes them to the *public* community database. `sourceRank` already ranks `.synthesized` at 0, so on merge they lose to human anchors — but for an audio-less *narrated* book the only anchors are `.synthesized`, so an upload would publish pure device-specific TTS timings.
- **Why:** Pollutes the shared community alignment payload. **Demoted from the agent's "High" to Medium on verification:** the upload is user-initiated from `BookSettingsView`, not automatic, and only audio-less narrated books are affected; the title|author|duration hash makes collision with a real audiobook unlikely.
- **Action:** Exclude `.synthesized` (and arguably all machine sources) from the `uploadAnchors` fetch query. One-line, clean pre-1.0 fix.
- **Severity: Medium** (verified-down from High).

### 6.2 Model download/extraction is now third-party (FluidAudio)
- **Location:** N/A in Echo (`ModelDownloader` deleted).
- **What:** The prior zip-slip/integrity finding is **moot** — FluidAudio's `KokoroAneResourceDownloader` now owns the HuggingFace download + extraction into Application Support. Echo no longer extracts archives.
- **Action:** Note for the model-swap (§3.1): if a model is vendored into the app bundle instead, there's no download attack surface; if a custom revision is fetched, re-apply checksum/zip-slip guards in whatever loader replaces FluidAudio's.
- **Severity: Low** (informational).

---

## 7. Performance

### 7.1 A whole chapter's PCM is buffered in memory before writing — ✅ RESOLVED (2026-06-15, stream-to-sink)
- **Location (was):** `NarrationService.swift` (collect all `chunks`, then one `audioWriter.write`).
- **What:** Every sub-chunk's `[Float]` samples for a chapter were retained until the chapter finished, then written once — unbounded PCM retention for a long chapter on a 4 GB A14.
- **Fix:** `AudioFileWriting` gained an incremental `makeStream(to:sampleRate:) -> AudioFileStream` session; `renderChapter` now opens the sink up front and `append`s each synthesized sub-chunk straight to disk, so peak memory is one ~200-char sub-chunk's PCM (~hundreds of KB) instead of a whole chapter's (tens of MB). The session is an `actor` (`ALACFileStream`) confining the non-`Sendable` `AVAudioFile`; ALAC losslessness preserved. Tests: `StreamingAudioWriterTests` (5) + unchanged `NarrationServiceTests`/`AVFoundationAudioWriterTests`. This is the half of the jetsam mitigation that does **not** need the model swap; the model-swap (§3.1) handles the ~300 MB resident-models half.
- **Severity (was): Medium** (mattered specifically for the 4 GB A14 target).

### 7.2 `ISO8601DateFormatter` allocated per `renderChapter` call
- **Location:** `NarrationService.swift:51`.
- **Action:** `static let`. **Severity: Low.**

### 7.3 No real on-device RTF / thermal measurement for the A14
- **Location:** `EchoTests/KokoroBenchmarkTests.swift` (now runs real synthesis, but on the simulator — no ANE, no thermals).
- **What:** There is still no measurement that answers "can the A14 sustain real-time narration?" — the figure the streaming-cushion (`lookAhead`) decision depends on. A simulator/Mac run cannot answer it.
- **Action:** Once §3.1 is unblocked, run a sustained multi-minute synthesis on the physical iPhone 12 Pro (ANE compute units, watch peak RAM + thermal state) and set `lookAhead` from real RTF.
- **Severity: Medium** (gating the cushion-size decision).

### 7.4 `lookAhead` render-ahead depth is a hardcoded constant
- **Location:** `PlayerModel+Narration.swift:89` (`let lookAhead = 2`).
- **Action:** Fine for v1; revisit after §7.3 gives real RTF/thermal data. **Severity: Low.**

---

## 8. SwiftUI / UI

### 8.1 The Play button doesn't start narration (owner design ask A)
- **Location:** `TransportControlsView.swift:54-64` (Play → `togglePlayPause`) → `PlaybackController.swift:116-153` (`play()` early-returns at `:123` on `state.tracks.isEmpty`).
- **What:** For an un-started audio-less narration book (`tracks.isEmpty == true`, `hasEPUB == true`, `narrationPlaybackState.isRunning == false`), pressing the main Play button is a no-op. Narration is only reachable via the "Listen" nudge → `VoicePickerView` → `startNarrationPlayback` (`NowPlayingTab.swift:41,95`).
- **Action:** Branch the Play action: when `hasEPUB && tracks.isEmpty && !narrationPlaybackState.isRunning`, start narration (with the default/last voice, or present the picker) instead of no-op'ing. The flags to gate on already exist.
- **Severity: Medium** (owner-requested).

### 8.2 `VoicePickerView` rows lack a selected style and a VoiceOver-visible selection
- **Location:** `VoicePickerView.swift` rows.
- **Action:** Add a clear selected style + `.accessibilityAddTraits(.isSelected)`. (Plan-1 carry-forward.)
- **Severity: Low.**

> **Resolved since the prior audit:** the narration UI is no longer dead code (mounted in `NowPlayingTab.swift:39-45,93-97`), and the Stats-tab dead-end is fixed (`RootTabView.swift:80-86` adds a "Done" toolbar button — commit `f89db91`). See Appendix A (§8.1-old, §8.3-old).

---

## 9. Dead code / duplication / tests

### 9.1 The `startNarrationPlayback` pipeline has no test coverage
- **Location:** `PlayerModel+Narration.swift:17-148` — no corresponding test file.
- **What:** The new pipeline (book-switch guards via `folderURL` comparison, look-ahead backpressure, pause-aware + at-gap-exempt render loop, resume slicing, error stamping) is entirely untested. The pure helpers (`NarrationChapterPlanner`, `NarrationFileNaming`, `NarrationCacheStore`, `NarrationTextChunker`) have unit tests; the orchestration that ties them together does not. The known `PlayerModel` iOS-26-sim isolated-deinit teardown crash means you can't construct a full `PlayerModel` in a test — so this needs the logic extracted to testable seams (a render-loop policy object / a coordinator) tested with `DatabaseService(inMemory:)` + mock `TTSEngine`.
- **Action:** Extract the loop policy (look-ahead/backpressure/resume decisions) into a pure, testable unit and cover it; keep the thin `PlayerModel` extension as glue.
- **Severity: Medium.**

### 9.2 `NarrationRenderPlanner` is dead
- **Location:** `NarrationRenderPlanner.swift:5-42`.
- **What:** `nextChapterToRender` has zero callers; render-ahead is implemented inline in the pipeline. (Note: `NarrationRenderPlanner.nextChapterToRender` can still form an inverted `Range` and trap if it's ever wired in without a bounds guard — fix on adoption or delete.)
- **Action:** Delete, or replace the inline loop with it as part of §9.1's extraction.
- **Severity: Low.**

### 9.3 `KokoroBenchmarkTests` can't answer the A14 question
- **Location:** `EchoTests/KokoroBenchmarkTests.swift`.
- **What:** Now exercises real synthesis (improved from the prior stub), but on the simulator it has no ANE and no thermals, so its RTF is not the production number.
- **Action:** Treat as a smoke test only; the real benchmark is the on-device run in §7.3.
- **Severity: Low.**

---

## 10. Cross-cutting recommendations

- **The whole feature is gated on §3.1.** Resolve the model-asset decision before any further device work — everything else is unverifiable until a real book narrates on the A14.
- **Extract the pipeline policy for testability (§9.1).** The single biggest quality gap now is that the most intricate new code (the render/backpressure/resume loop) is the least tested, because it lives on the untestable `PlayerModel`.
- **Raise `SWIFT_STRICT_CONCURRENCY` to `targeted`** for the narration module to surface cross-actor issues before the Swift-6 migration forces them.
- **Keep the `anchoredOnly` shield, but fix the general interpolation (§5.2)** so MP3-folder/multi-m4b read-along is correct independent of narration.
- **License discipline for the model swap:** the v1 constraint is English-only with clean permissive G2P and **no GPL espeak-ng in the dependency graph** — verify the replacement model's phonemizer licensing before adopting (the FluidAudio Misaki frontend is currently what satisfies this).
- **Doc sync (per CLAUDE.md):** `ARCHITECTURE.md`'s "On-Device Narration" section and `README.md` will need updating once the model-swap lands (the engine description currently says FluidAudio/ANE chunking). Flagged, not yet changed (no feature code this pass).

---

## 11. What was NOT audited

- **Real Kokoro inference correctness / audio quality** — blocked by §3.1; no real A14 output to assess.
- **Running the app or the device build** — read-only audit; all non-audio-whine fixes remain **device-UNVERIFIED** (read-along-follows-chapter, EPUB-file import loads the real book, resume behavior).
- **FluidAudio internals beyond the compute-unit routing + manager init** that bear on §3.1.
- **The `mattmireles/kokoro-coreml` model internals / its G2P license** — flagged as a must-verify in the plan, not yet confirmed.
- **A fresh compiler-warning capture** — no clean build run this pass (16 GB machine constraints + concurrent automation on the branch).
- **The broader repo** — only the narration slice + its direct read-along/sync touchpoints.

---

## 12. Verification

Each Critical/High was confirmed by opening the cited lines and, where applicable, the crash log + git history:

- **§3.1 (Critical)** — `KokoroTTSEngine.swift:6` `KokoroAneManager()`; FluidAudio `KokoroAneManager.swift:47` `init(computeUnits: KokoroAneComputeUnits = .default)`; `xcsym` summary of `Echo-2026-06-15-075346.ips` → crashed thread on `com.apple.e5rt.concurrentExecutionQueue`, frame `BNNSGraphContextExecute_v2`, zero app frames; git: `git show 613c577` (revert from `units.vocoder = .cpuAndGPU` back to `KokoroAneManager()`), and `69c4a71`/`c0e6e98`/`153d3c4` all `KokoroAneManager()` (= `.default`) while both crash logs were captured. Confirmed Critical; upstream/hardware.
- **§5.1 (High)** — `PlayerModel+Narration.swift:38-46` evicts `staleVoiceFiles` synchronously at function entry; `:22` cancels the render but does not stop the AVPlayer; track replacement is later at `:120-123`. Confirmed High.
- **§5.2 (High)** — `AlignmentService.swift:430` `findBracketingAnchors` sorts the whole `anchoredBlocks` by `sequenceIndex`; `:340` interpolation guarded only by `!anchoredOnly`; `NarrationService.swift:134-135` passes `anchoredOnly: true`. Confirmed High.
- **§6.1 (Medium, verified-down from High)** — `CloudKitSyncService.swift:86-88` fetch by `audiobook_id` with no source predicate; `:57` `sourceRank(.synthesized) == 0`; caller is `BookSettingsView` (user-initiated). Confirmed Medium.
- **§8.1 (Medium)** — `PlaybackController.swift:123` `guard !state.tracks.isEmpty else { return }`; `TransportControlsView.swift:58` Play → `togglePlayPause`. Confirmed.

---

## Appendix A — Prior-audit (PR #61 era) reference map

External references to the old §-numbers resolve here. The old detailed audit is preserved in git history (this file before 2026-06-15).

| Prior § | Topic | Disposition (2026-06-15) | Now |
|---|---|---|---|
| §3.1 | `cancelNarration` never cancels | **RESOLVED** | render task stored + cancelled — `PlayerModel+Narration.swift:22,52` |
| §3.2 | AAC encode + DB on main actor | **RESOLVED** | off-main encode + single `await db.write` — `NarrationService.swift:115-119` |
| §3.3 | Kokoro calls `@MainActor` phonemizer | **MOOT** | `MisakiPhonemizer` deleted (FluidAudio G2P) |
| §3.4 | ModelDownloader non-atomic extract | **MOOT** | `ModelDownloader` deleted (FluidAudio download) |
| §5.1 | re-render non-idempotent | **RESOLVED** | `save`/upsert in one transaction — `NarrationService.swift:115-119` |
| §5.2 | export filename mismatch | **RESOLVED** | shared `NarrationFileNaming` helper |
| §5.3 | `synthesize` is a stub | **RESOLVED** | real FluidAudio inference — `KokoroTTSEngine.swift:28` |
| §5.5 | AudioMarkerStub writes no chapters | **STILL-OPEN** | now §5.4 |
| §5.6 | benchmark measures nothing | **CHANGED** | now §7.3/§9.3 (runs real synth, still sim-only) |
| §5.11 | files in `temporaryDirectory` | **RESOLVED** | Application Support, backup-excluded — `PlayerModel+Narration.swift:153-164` |
| §6.1 | model download zip-slip | **MOOT** | now §6.2 (third-party) |
| §6.2 | synthesized anchors → public CloudKit | **STILL-OPEN** | now §6.1 |
| §7.1 | whole-chapter PCM buffered | **RESOLVED** | stream-to-sink — `AudioFileStream`/`ALACFileStream` (2026-06-15) |
| §7.2 | ISO8601 per call | **STILL-OPEN** | now §7.2 |
| §8.1 | entire narration UI dead | **RESOLVED** | mounted — `NowPlayingTab.swift:39-45,93-97` |
| §8.3 | Stats-tab dead-end | **RESOLVED** | "Done" button — `RootTabView.swift:80-86` (`f89db91`) |
| §9.2 | `NarrationRenderPlanner` dead | **STILL-OPEN** | now §9.2 |
| §9.3 | ModelDownloader + loadModel dead | **MOOT** | deleted |
| §9.4 | `BookDetailViewModel` hard-constructs engines | **MOOT** | `BookDetailViewModel` deleted (single pipeline route) |
| — | read-along write-side gap (live `timeline_item`) | **RESOLVED** | `renderChapter` recalcs `anchoredOnly:true` + posts `.timelineItemsIngested` — `NarrationService.swift:121-149` |
