# Narration Feature — Code Audit

**Scope:** the on-device narration feature as merged to `main` — `EchoCore/Services/Narration/*`, `EchoCore/Views/Narration/*`, `EchoCore/ViewModels/BookDetailViewModel.swift`, `Schema_V17`, and the narration-touched bits of `AlignmentAnchorRecord` / `TrackRecord` / `DatabaseService` / `CloudKitSyncService`. Read-only. Method: 5 parallel audit lenses + adversarial verification of every Critical/High (which dropped 1 false positive and demoted several overstated severities).

**Verdict in one line:** Plan 1's mock-backed core (PR #58) is sound. Everything PR #61 added on top — Kokoro inference, Misaki G2P, model download, `.m4b` export, the "benchmark," and the UI — is **non-functional spike code merged as if finished.** It is not currently hurting users only because the entire narration UI is dead code (never mounted). Treat the feature as **not shipped**, regardless of the "Finish Kokoro…" merge message.

> **Status update — 2026-06-14 (narration pipeline-playback plan).** The stack has moved well past the "spike merged as finished" state this audit captured:
> - **Engine is real.** Kokoro-82M runs on-device via FluidAudio/ANE (confirmed producing audio on an iPhone 12 Pro). The 4 confirmed-High engine bugs — §3.1 (cancel), §3.2 (main-actor encode/DB), §5.1 (idempotency), §5.2 (export prefix) — were addressed earlier (commit `c0e6e98`).
> - **Single narration route (iPhone + CarPlay).** `BookDetailViewModel` and its standalone `AVAudioPlayer` path are **deleted**; the iPhone "Listen" UI now drives the same `PlayerModel.startNarrationPlayback` pipeline as CarPlay, so lock-screen transport, the scrubber, and Now Playing all work. This resolves §8.1 (dead UI slice) and **removes the "iOS path divergent" caveat — there is no longer a second playback path.**
> - **Also resolved by the pipeline-playback plan:** the first-open race (narration awaits the no-audio EPUB import before reading blocks); rendered audio moved out of `temporaryDirectory`/`Caches` into a backup-excluded **Application Support** store (§5.11), with stale-voice eviction; render-ahead is now **bounded** (look-ahead 2) and pause-aware (with an at-gap exemption so render/playback can't deadlock); resume-at-last-chapter on reopen; an interim "Preparing narration…" Now Playing state during the first render.
> - **Still open from this audit (untouched by that plan):** security §6.1 (untrusted-zip / zip-slip) and §6.2 (synthesized anchors in the *public* CloudKit payload), plus the perf/quality items in §7 and §9. Re-audit before 1.0.

> **Device-test fixes — 2026-06-15.** On-device testing (iPhone 12 Pro, iOS 26.5) surfaced and fixed two runtime issues outside this audit's static scope:
> - **Synthesis crash RESOLVED (commit `3317a28`).** Kokoro synthesis trapped with an uncatchable `EXC_BREAKPOINT`/SIGTRAP inside CoreML/`libBNNS` (`BNNSGraphContextExecute_v2`) when a whole 400+ char EPUB block was synthesized in one call. FluidAudio does no internal chunking — it caps IPA at ~510 phonemes and expects the caller to "chunk longer prompts upstream" — and the palettized vocoder's BNNS fallback traps on the resulting dynamic tensor shape (a trap, not a Swift throw, so it can't be caught — only prevented). Fix: `NarrationService.renderChapter` now splits each block into ~200-char sentence sub-chunks via the new pure `NarrationTextChunker` and synthesizes each separately, **preserving one alignment anchor per original block** (spanning the summed sub-chunk durations); a FluidAudio length-cap throw now skips that sub-chunk instead of aborting the chapter.
> - **Constant audio whine RESOLVED (commit `6111d7c`).** The rendered cache was 64 kbps AAC; a lossless round-trip test proved the encoder injected the artifact. The cache now writes **Apple Lossless (ALAC)** in the same `.m4a` container (filenames unchanged); the on-device whine is gone (user-confirmed).
> - **Found this round, in progress:** read-along still doesn't populate `timeline_item` live as narration renders (write-side gap — `renderChapter` writes `alignment_anchor` but never calls `recalculateTimeline` / notifies the reader); and the Stats tab has no exit affordance for an audio-less book (`tracks.isEmpty` disables the only tab-cycle exit).

---

## 1. Executive summary

1. **[High] The post–Plan-1 narration stack is unfinished spike code wired as production** — Kokoro engine, phonemizer, downloader, m4b writer, and benchmark are all stubs that compile but don't work — §9.1 (umbrella) / §5.3, §5.4, §5.5, §5.6.
2. **[Medium · mitigating] None of it reaches users yet** — the whole narration UI slice is dead code; no parent view mounts it and `BookDetailViewModel` is never constructed — §8.1.
3. **[High] Export is dead-on-arrival** — the writer names files `<id>-ch<n>-<voice>.m4a`; the exporter filters by prefix `narration_<bookID>_`, so it always finds zero files — §5.2 — `NarrationExportService.swift:19,24` vs `NarrationService.swift:73-74`.
4. **[High] `cancelNarration()` never cancels** — the render `Task` handle is discarded; cancel only resets the UI, and the render keeps running, writes to the DB, and mutates `NarrationState` *after* reset — §3.1 — `BookDetailViewModel.swift:45-62`.
5. **[High] AAC encode + all DB writes run on the main actor** — only Kokoro inference is off-main; the encode and N synchronous SQLite transactions block the main thread per chapter, violating CLAUDE.md's "UI never freezes" rule — §3.2 — `NarrationService.swift:41-89`, `AVFoundationAudioWriter.swift:5-51`.
6. **[High] `renderChapter` re-render is non-idempotent** — `anchorDAO.insert` throws on the deterministic duplicate PK, after the track was already upserted → partial write. This is the Plan-1 carry-forward that PR #61 never fixed — §5.1 — `NarrationService.swift:79-86`.
7. **[Medium] The "on-device benchmark" measures nothing** — it instantiates the engine with no model, returns *before* even the `Task.sleep`, runs on Mac/simulator, and the RTF print is over a fabricated duration. It cannot answer the A14/Neural-Engine question — §5.6 — `KokoroBenchmarkTests.swift:6-27`.
8. **[Medium] `.m4b` export writes no chapters** — `AudioMarkerStub.writeChapters` only copies the file while its own comment claims it "inserts the Nero chapter atoms and `stik` flags" — §5.5 — `AudioMarkerStub.swift:10-19`.
9. **[Medium] `BookDetailViewModel` hard-constructs concrete engines**, defeating the `TTSEngine`/`AudioFileWriting` `Sendable` seams — re-introducing the exact protocol-DI theater the team just deleted in PR #62 — §9.4.
10. **[Medium/Low] Security latent (both currently unreachable):** the model downloader extracts an untrusted HuggingFace zip into Application Support with no checksum/signature/zip-slip guard (§6.1); synthesized anchors land in the same table `CloudKitSyncService` uploads to the *public* community payload, with no exclusion (§6.2).

**Confirmed-High set (will bite the moment the stubs become real):** §3.1, §3.2, §5.1, §5.2. **Verified severity distribution:** 4 confirmed High, ~18 Medium, ~12 Low (down from 25 raw "High" after verification dropped 1 and demoted the not-user-reachable stub items).

---

## 2. Quick wins (≤30 min each)

- **§2.1** Delete or `#if DEBUG`-gate the dead `print()` RTF "benchmark" in `KokoroTTSEngine.synthesize` (`KokoroTTSEngine.swift:44`) and route any real logging through `Logger`, not stdout. **Severity: Low.**
- **§2.2** Fix the export prefix so writer and reader agree (one-line contract fix) — see §5.2. **Severity: High (but trivial).**
- **§2.3** Remove the dead `VoiceCatalog.sampleClipName` field (set on all 4 voices, read by nothing) — §9.6. **Severity: Low.**
- **§2.4** Correct or delete the false comment in `AudioMarkerStub.writeChapters` that claims to write chapter atoms — §5.5. **Severity: Low (honesty).**
- **§2.5** Hoist the per-call `ISO8601DateFormatter` to a `static let` — §7.2. **Severity: Low.**

---

## 3. Concurrency

### 3.1 `cancelNarration()` never cancels the render Task; the render writes to the DB and corrupts state after "cancel"
- **Location:** `EchoCore/ViewModels/BookDetailViewModel.swift:45-62`; gates at `NarrationService.swift:53,72,77`.
- **What:** `startNarration` launches an unstructured `Task { try await narrationService.renderChapter(...) }` and **discards the handle** (no stored `Task` property). `cancelNarration()` calls only `narrationState.reset()` — it never `.cancel()`s anything, and there is no `deinit`. The three `Task.checkCancellation()` gates in `renderChapter` can therefore never fire in production.
- **Why:** Tapping cancel resets the UI to `.idle` while the render keeps synthesizing, then proceeds past the last gate to insert the track + all `.synthesized` anchors anyway — silent state divergence, wasted battery, and a fully-written chapter the user thought they cancelled. The *same* `NarrationState` is then mutated by the still-running task after `reset()`, corrupting the displayed state. The only cancellation test (`NarrationServiceTests.swift:104`) drives the `Task` handle directly, so it passes while the real path is unprotected — masking the bug.
- **Action:** Store the render task on the view model (`private var renderTask: Task<Void, Never>?`), cancel-and-replace in `startNarration`, cancel it in `cancelNarration()` and `deinit`, and only `reset()` after. Mirror `AutoAlignmentService.startAutoAlignment`, which returns a `Task` the UI stores.
- **Severity: High** (confirmed).

### 3.2 AAC encode and all DB writes run on the main actor
- **Location:** `NarrationService.swift:41-89`; `AVFoundationAudioWriter.swift:5-51`; `TrackDAO.swift:16-22`; `AlignmentAnchorDAO.swift:11-16`.
- **What:** The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. `AVFoundationAudioWriter` is a plain struct (no isolation) → implicitly `@MainActor`, so its AAC encode + buffer fill + `audioFile.write` loop run on the main actor. `renderChapter` is `@MainActor` and calls GRDB's **synchronous** `db.write { }` (via the DAOs) directly — N+1 SQLite write transactions on the main thread. Only `await tts.synthesize(...)` leaves the main actor (Kokoro is an explicit `actor`).
- **Why:** The class doc claims it "mirrors `AutoAlignmentService`," but that service offloads heavy work to separately-isolated helpers reached via `await`. Here a whole chapter's AAC encode and all DB writes hitch/freeze the UI on every render — directly contradicting CLAUDE.md's "UI never freezes during data operations."
- **Action:** Make `AVFoundationAudioWriter` `nonisolated` and run the encode on the cooperative pool (`@concurrent`) or inside an actor. Replace synchronous DAO calls in `renderChapter` with `try await db.write { }`, batching the track + anchors into one transaction (also fixes §5.1, §7.3).
- **Severity: High** (confirmed).

### 3.3 `KokoroTTSEngine` calls `@MainActor`-isolated `MisakiPhonemizer` synchronously from inside an actor
- **Location:** `KokoroTTSEngine.swift:6,19`; `MisakiPhonemizer.swift:6`.
- **What:** `KokoroTTSEngine` is an `actor`, but its `phonemizer` is a plain struct → implicitly `@MainActor`. `synthesize` (actor-isolated) calls `phonemizer.phonemize(text)` with no `await`. It only compiles because `SWIFT_STRICT_CONCURRENCY` is unset (`minimal`), which suppresses the cross-actor diagnostic.
- **Why:** Pins G2P to the main actor — defeating the off-main intent — and becomes a hard error under strict/Swift-6 concurrency.
- **Action:** Mark `MisakiPhonemizer` `nonisolated`/`Sendable`. Raise `SWIFT_STRICT_CONCURRENCY` to `targeted` for the module so these surface at compile time (see §10).
- **Severity: Low** (verified down from High — latent, not currently a defect under the project's compile mode).

### 3.4 `ModelDownloader` extraction is non-atomic — partial extraction poisons the cached-model check
- **Location:** `ModelDownloader.swift:25-56`.
- **What:** Unzips directly into Application Support with no temp-dir-then-atomic-move, no post-extraction validation, and sets `.completed` regardless. A cancel/crash mid-extract leaves a partial model that the "is it already downloaded?" check then treats as present.
- **Action:** Extract to a temp dir, validate the expected files exist, then atomically move into place; treat any partial state as "not downloaded." (Currently unreachable — see §9.3.)
- **Severity: Medium.**

### 3.5 Mock test doubles are `@unchecked Sendable` with unsynchronized mutable state
- **Location:** `EchoTests/Mocks/MockTTSEngine.swift:6-20`; `MockAudioWriter.swift:6-15`.
- **What:** Both mutate arrays from `@unchecked Sendable` types with no synchronization and never exercise off-main execution, so the tests can't catch the §3.1/§3.2 isolation problems.
- **Action:** Acceptable for serial tests, but add at least one test that drives `renderChapter` off the main actor / through the real cancellation path.
- **Severity: Low.**

---

## 4. API modernity

_No findings._ No deprecated or about-to-be-removed APIs in the narration slice. (The relevant modernity issue is the suppressed strict-concurrency mode — see §3.3 and §10.)

---

## 5. Bugs / logic errors

### 5.1 `renderChapter` re-render is non-idempotent → partial write
- **Location:** `NarrationService.swift:79-86` (with `TrackDAO.swift:16-22`, `AlignmentAnchorDAO.swift:11-16`).
- **What:** Track id `syn-<audiobookID>-ch<n>` is saved via `save` (upsert, succeeds on re-run), but anchor id `syn-<audiobookID>-<blockID>` is written via plain `insert`, which **throws on duplicate PK**. The two are in separate transactions, so a re-render upserts the track then throws on the first anchor — leaving an orphan track + partial anchors.
- **Why:** A voice change or crash-resume re-renders a chapter; this is exactly that path. It's the Plan-1 review carry-forward that PR #61 did not address.
- **Action:** Use `save`/upsert for anchors too, inside a **single** `db.write` transaction with the track (fixes idempotency + atomicity + §3.2 + §7.3 together). Mirror `AutoAlignmentService`'s batch `insertAnchors`.
- **Severity: High** (confirmed).

### 5.2 Export pipeline is dead on arrival — writer/exporter filename mismatch
- **Location:** `NarrationExportService.swift:19,24` vs `NarrationService.swift:73-74`.
- **What:** The writer names cache files `<audiobookID>-ch<n>-<voice>.m4a`; `exportChapterFiles` filters by `hasPrefix("narration_<bookID>_")`. The `narration_` prefix appears nowhere the writer produces, so export *always* returns zero files.
- **Action:** Make the producer and consumer share one filename helper. **Severity: High** (confirmed).

### 5.3 `KokoroTTSEngine.synthesize` is a stub — no inference, empty samples, fake RTF
- **Location:** `KokoroTTSEngine.swift:18-47`.
- **What:** The CoreML steps are comments (lines 28-32). With a model loaded it `Task.sleep`s for `text.count*2 ms` and returns `TTSChunk(samples: [], duration: text.count*0.08)`; with no model (the only real state — `loadModel` is never called, §9.3) it returns empty samples too. The RTF `print` measures the sleep.
- **Why:** Production renders silent audio; the "benchmark" is meaningless (§5.6). Clearly labeled a "spike" in comments, and not user-reachable (§8.1) — hence Medium, not High.
- **Action:** Implement real inference (real input/output tensor shapes — currently a TODO, not even guessed) before wiring to any user path, or keep it explicitly behind a mock flag.
- **Severity: Medium** (verified down from High — labeled spike, not reachable).

### 5.4 `MisakiPhonemizer` is a passthrough lowercaser, not G2P
- **Location:** `MisakiPhonemizer.swift:10-28`.
- **What:** `phonemize` tokenizes with `NLTokenizer` and returns `word.lowercased()` joined by spaces. No `MisakiSwift` package is linked (`Package.resolved` has no match). Comments label it a "naive mapping for demonstration."
- **Action:** Integrate the real Apache-licensed G2P (no espeak-ng) before relying on phoneme-derived timing.
- **Severity: Low** (verified — clearly a stub, unreachable).

### 5.5 `AudioMarkerStub.writeChapters` writes no chapter atoms despite claiming to
- **Location:** `AudioMarkerStub.swift:10-19` (caller `NarrationExportService.swift:75-83`).
- **What:** It `removeItem` + `copyItem` only — no `chpl`/Nero atoms, no `stik` flag — while the inline comment says it "inserts the Nero chapter atoms and `stik` flags." `exportM4B` builds a chapters array, passes it in, and it's ignored. The output `.m4b` is a chapterless `.m4a` renamed.
- **Action:** Either integrate the real atom writer (`atelier-socle/swift-audio-marker`, Apache) or fix the comment + downgrade the export's claims so it doesn't promise chapters it can't deliver.
- **Severity: Medium** (verified — the false comment is the real hazard).

### 5.6 The "on-device benchmark" measures `Task.sleep` on Mac/simulator
- **Location:** `EchoTests/KokoroBenchmarkTests.swift:6-27` (+ `KokoroTTSEngine.swift:18-47`).
- **What:** The test builds `KokoroTTSEngine()` with `model = nil`, so `synthesize` returns at the no-model guard *before* the sleep and the RTF print. Even if it didn't, a unit test runs on the Mac/simulator with **no Neural Engine** (CoreML falls back to CPU/GPU) and no phone thermals.
- **Why:** This is the number the feature's "benchmark" commit shipped on. It cannot answer "can the A14 sustain real-time narration?" — that requires the physical iPhone 12 Pro.
- **Action:** Replace with a real on-device measurement plan (physical device, ANE compute units, sustained multi-minute thermal run). Until then, do not treat any RTF figure as real.
- **Severity: Medium** (verified).

### 5.7 `AVFoundationAudioWriter` persists a zero-content file with a fabricated duration
- **Location:** `AVFoundationAudioWriter.swift:29-51`; fed by `NarrationService.swift:62,75-85`; `KokoroTTSEngine.swift:24,46`.
- **What:** The writer is a *correct* `AVAudioFile` implementation, but it only ever receives empty-sample chunks (§5.3). It `guard frameCount > 0 else { continue }`-skips every chunk, so the `.m4a` is empty while the track/anchor durations come from the stub's fabricated `chunk.duration` — track says non-zero, file is silent.
- **Action:** Resolves once §5.3 produces real samples. No change to the writer itself.
- **Severity: Low** (verified — downstream of the stub, not a writer bug).

### 5.8 `NarrationRenderPlanner.nextChapterToRender` can form an inverted Range and crash
- **Location:** `NarrationRenderPlanner.swift:31-38`.
- **What:** When `currentPlayingChapter` exceeds the last index, the computed range is inverted (`lower > upper`), which traps at runtime.
- **Action:** Clamp/guard the bounds. (Currently unreachable — the planner is dead, §9.2 — but fix before wiring render-ahead.)
- **Severity: Medium.**

### 5.9 Track/anchor duration disagreement on empty chunks
- **Location:** `AVFoundationAudioWriter.swift:31,47` with `NarrationService.swift:60-65`.
- **What:** Empty-sample chunks contribute 0 to the file duration but non-zero to the anchor times, so anchors point past the end of the (empty) audio.
- **Action:** Resolves with §5.3; also assert `chunk.samples.count` matches `chunk.duration * sampleRate` defensively.
- **Severity: Low.**

### 5.10 Export fabricates book metadata
- **Location:** `NarrationExportService.swift:49`; `BookDetailViewModel.swift:72`.
- **What:** Chapter titles are hard-coded `"Chapter N"` and the book title is passed as `"Unknown Title"` — real titles are never used.
- **Action:** Thread the real `AudiobookRecord` title/author + EPUB chapter titles through.
- **Severity: Medium.**

### 5.11 Narration files are written to `temporaryDirectory`
- **Location:** `BookDetailViewModel.swift:30`; `NarrationService.swift:73-83`.
- **What:** `cacheDirectory` is `FileManager.temporaryDirectory`, which iOS can purge at any time — orphaning the persisted `track.filePath` (playback then fails with a missing file).
- **Action:** Write narration audio into Application Support (or the App Group container) under a stable, backed-up path.
- **Severity: Medium.**

### 5.12 `TextNormalizer` abbreviation expansion isn't word-boundary aware
- **Location:** `TextNormalizer.swift:15-22`.
- **What:** `replacingOccurrences` for `Dr.`/`e.g.` fires mid-word (`Dr.ink`). This is the Plan-1 review carry-forward, unaddressed.
- **Action:** Make abbreviation expansion regex/word-boundary aware (the task spec for this was already written — see the overnight `02-textnormalizer-hardening` task).
- **Severity: Low.**

---

## 6. Security

### 6.1 Model downloader extracts an untrusted archive with no integrity or zip-slip guard
- **Location:** `ModelDownloader.swift:22-51`.
- **What:** A hardcoded, unpinned HuggingFace `resolve/main` URL is downloaded and `unzipItem`'d straight into Application Support — no SHA-256, no signature, no path-traversal (zip-slip) guard on entry names, no post-extraction validation.
- **Why:** A compromised/MITM'd archive could write outside the intended directory or plant a malicious model. Demoted to Medium because the downloader is **never called** (§9.3) — but fix before it goes live.
- **Action:** Pin to an immutable revision, verify a known SHA-256 of the archive, reject entries with `..`/absolute paths, validate expected files post-extract.
- **Severity: Medium** (verified down from High — latent/unreachable).

### 6.2 Synthesized TTS anchors are not excluded from the public CloudKit community payload
- **Location:** `NarrationService.swift:56-63,85`; `CloudKitSyncService.swift:53-89`.
- **What:** `renderChapter` writes `source = .synthesized` anchors into the same `alignment_anchor` table that `CloudKitSyncService.uploadAnchors` fetches by `audiobook_id` and pushes to the **public** database. There's no filter excluding synthesized anchors.
- **Why:** TTS-generated, device-specific anchors could leak into the shared community alignment payload, polluting it for real-audiobook users. (Largely unreachable today since narration isn't wired up.)
- **Action:** Exclude `.synthesized` (and arguably all machine sources) from the upload query, or scope community sync to real-audiobook anchors only.
- **Severity: Low** (verified — mechanism real, impact gated).

---

## 7. Performance

### 7.1 `renderChapter` accumulates a whole chapter's PCM in memory before writing
- **Location:** `NarrationService.swift:47-75`.
- **What:** All `[Float]` chunks for a chapter are collected, then written once — unbounded PCM retention for a long chapter.
- **Action:** Stream each chunk to the `AudioFileWriting` sink as it's produced, rather than buffering the whole chapter.
- **Severity: Medium.**

### 7.2 `ISO8601DateFormatter` allocated per `renderChapter` call
- **Location:** `NarrationService.swift:13-14,50`.
- **Action:** Hoist to a `static let` (the codebase convention — `AlignmentService`, `EPubBlockDAO`, `Note` all do this).
- **Severity: Low.**

### 7.3 Track + N anchors written across N+1 separate transactions
- **Location:** `NarrationService.swift:84-85` (contrast `AlignmentService.swift:137`).
- **What:** Non-atomic and slow — each anchor is its own SQLite transaction. Diverges from `AutoAlignmentService`'s batch insert.
- **Action:** One `db.write` transaction (also fixes §3.2 and §5.1).
- **Severity: Medium.**

---

## 8. SwiftUI / UI

### 8.1 The entire narration UI slice is dead code
- **Location:** `Views/Narration/NarrationNudgeView.swift`, `NarrationStatusView.swift`, `VoicePickerView.swift`; `BookDetailViewModel.swift:1-94`.
- **What:** No parent view mounts any of these, and `BookDetailViewModel` is never constructed (no call sites). The "read-first Listen nudge" from the spec is not wired into `NowPlayingTab` or anywhere else.
- **Why:** This is the *mitigating* finding — it's why none of §3/§5 reach users — but it also means the feature is entirely non-functional end to end despite being merged as "finished."
- **Action:** Either wire the nudge into the book/player surface (the real Plan 4) or clearly mark the slice as not-yet-integrated. Don't leave it merged-but-unmounted, which reads as "done."
- **Severity: Medium.**

### 8.2 `VoicePickerView` confirmation always passes `blocks: []`
- **Location:** `VoicePickerView.swift:42-48`; `BookDetailViewModel.swift:42-58`.
- **What:** "Start Narration" calls through with an empty blocks array, so even if the UI were mounted and the engine real, it would render nothing.
- **Action:** Fetch the book's `epub_block`s for the chapter and pass them through.
- **Severity: Medium.**

### 8.3 Export errors are swallowed with `print`, with no UI surface for results
- **Location:** `BookDetailViewModel.swift:66-93`; `NarrationExportService.swift:49`.
- **Action:** Surface success/failure + the resulting file (share sheet) in the UI; route errors through `Logger` and a user-visible state.
- **Severity: Medium.**

### 8.4 `VoicePickerView` rows lack selected-state styling and a VoiceOver-visible selection
- **Location:** `VoicePickerView.swift:24-32`.
- **What:** No visible selected styling; the checkmark is decorative/hidden from VoiceOver with no accessibility replacement.
- **Action:** Add a clear selected style + `.accessibilityAddTraits(.isSelected)`.
- **Severity: Low.**

### 8.5 `NarrationStatusView` shows the spinner only for `.preparingChapter`
- **Location:** `NarrationStatusView.swift:10-13`.
- **What:** `.renderingAhead` shows progress text but no activity indicator (moot today since render-ahead is dead, §9.2).
- **Severity: Low.**

---

## 9. Dead code / duplication / refactor

### 9.1 The post–Plan-1 narration stack is non-functional spike code merged as production
- **Location:** `KokoroTTSEngine.swift`, `MisakiPhonemizer.swift`, `ModelDownloader.swift`, `AudioMarkerStub.swift`, `KokoroBenchmarkTests.swift` (umbrella; specifics in §5.3-§5.6, §6.1).
- **What:** Every "real" component PR #61 added is a stub or placeholder, wired together end-to-end, merged with a "Finish Kokoro AI narration export features" message. It compiles and is referenced, so it reads as complete in the codebase.
- **Why:** The biggest risk here isn't a crash — it's the *false sense of completion*. A solo dev tracking "what's done" will believe narration works; it does not produce a single second of real audio.
- **Action:** Explicitly mark the feature in-progress (feature flag / `// SPIKE — not functional` headers / a `NARRATION_STATUS.md`), and treat §5.3-§5.6 as the real remaining work — to be done interactively, with the physical device for the benchmark.
- **Severity: High** (umbrella).

### 9.2 `NarrationRenderPlanner` + the `.renderingAhead` phase are dead
- **Location:** `NarrationRenderPlanner.swift:5-42`; `NarrationState.swift:10`.
- **What:** The render-ahead architecture is declared but never invoked; `.renderingAhead` is never entered.
- **Action:** Wire it into the playback-driven scheduler (Plan 4) or remove until then.
- **Severity: Medium.**

### 9.3 `ModelDownloader` is dead and `KokoroTTSEngine.loadModel` has zero callers
- **Location:** `ModelDownloader.swift:5-57`; `KokoroTTSEngine.swift:12-16`.
- **What:** The model lifecycle is unimplemented — nothing downloads or loads a model, so the engine always runs the no-model stub branch.
- **Action:** Implement the download→load→cache lifecycle as part of finishing §5.3.
- **Severity: Medium.**

### 9.4 `BookDetailViewModel` hard-constructs concrete engines, defeating the Sendable seams
- **Location:** `BookDetailViewModel.swift:20-40` (esp. 28-29).
- **What:** It directly news up `KokoroTTSEngine()` and `AVFoundationAudioWriter()` instead of injecting the `TTSEngine`/`AudioFileWriting` protocols Plan 1 deliberately created — re-introducing the exact "protocol-DI theater" the team just deleted in PR #62 (§10.1 of the prior audit).
- **Action:** Inject the protocols via the initializer; build the live graph in an assembly/factory. This also makes the UI testable with the mocks.
- **Severity: Medium.**

### 9.5 Plan-1 carry-forward not addressed: `NarrationState.log` drops the timestamp and is unused
- **Location:** `NarrationState.swift:22,31` (contrast `AutoAlignmentState.swift:36-41`).
- **What:** `log` omits the `[HH:mm:ss]` prefix `AutoAlignmentState` adds, and `log`/`debugLog` are never called.
- **Action:** Align with `AutoAlignmentState` if a debug log view is intended; otherwise remove.
- **Severity: Low.**

### 9.6 `VoiceCatalog.sampleClipName` is dead
- **Location:** `VoiceCatalog.swift:7,15,18,21,24`.
- **What:** Set on all four voices, read by nothing (the voice-preview clips were never built).
- **Action:** Remove until preview is implemented.
- **Severity: Low.**

### 9.7 All synthesized anchors are `.point` kind, including chapter boundaries
- **Location:** `NarrationService.swift:61`.
- **What:** Diverges from `AutoAlignmentService`, which distinguishes chapter start/end kinds — and `.point` with a non-nil `audioEndTime` is a new semantic for that kind.
- **Action:** Use the appropriate `anchorKind` for chapter boundaries, or document the deliberate choice.
- **Severity: Low.**

### 9.8 Force-unwraps on FileManager URLs and force-try regex compilation
- **Location:** `ModelDownloader.swift:17,43`; `TextNormalizer.swift:27-28,37,43`.
- **What:** Robust for valid inputs, but unguarded — a `FileManager` URL force-unwrap is a crash vector in edge environments.
- **Action:** Guard the URL lookups; `static let` the regexes (compile once, force-try at init is acceptable for constant patterns).
- **Severity: Low.**

---

## 10. Cross-cutting recommendations

- **Treat the feature as a spike, not shipped.** The single most important action: stop the codebase reading as if narration works. Feature-flag it, header the stub files, or add a status doc. §9.1.
- **The Plan-1 carry-forwards were silently dropped by PR #61** — idempotency (§5.1), normalizer hardening (§5.12), log timestamp (§9.5). The overnight task files already drafted for two of these still apply.
- **Raise `SWIFT_STRICT_CONCURRENCY` to `targeted` for this module.** It currently compiles under `minimal`, which hides the real cross-actor and main-actor issues (§3.2, §3.3). Turning it up surfaces them at compile time before the Swift-6 migration forces them as errors.
- **Comments must not claim capabilities the code lacks** (§5.5, the "benchmark"). For a solo dev this is a direct path to shipping something broken believing it works.
- **Re-apply the injection discipline from Plan 1.** §9.4 re-introduces the protocol-DI theater the team just removed; inject the seams.
- **Real benchmarking needs the device.** No simulator/Mac measurement answers the A14/ANE question (§5.6) — that's an interactive, physical-device task.

---

## 11. What was NOT audited

- **The Plan-1 mock-backed core in depth** (`TTSEngine`/`TTSChunk`/`VoiceID`/`NarrationState`/`TextNormalizer` core/`NarrationService` skeleton) — reviewed and merged in PR #58; this audit focused on PR #61's additions.
- **A fresh compiler-warning capture** — relied on code analysis (the module builds green on CI). A clean build with `SWIFT_STRICT_CONCURRENCY=targeted` would likely surface the §3.x items as warnings.
- **Running the app or tests** — read-only audit.
- **Real Kokoro inference correctness** — there is no inference to assess (§5.3 is a stub).
- **Third-party package internals** — none are linked for Kokoro/Misaki/m4b (that absence is itself §5.4/§5.5).
- **Build settings** beyond the actor-isolation/strict-concurrency flags noted.
- **The broader repo** — only the narration slice listed in Scope.

---

## 12. Verification

Each confirmed High (and the load-bearing Mediums) was checked by opening the cited lines:

- **§3.1** — `BookDetailViewModel.swift:45` launches `Task { renderChapter(...) }` with no stored handle; `:60-62` `cancelNarration` calls only `reset()`; `NarrationState.reset()` (`NarrationState.swift:49-57`) holds no Task reference. Confirmed High.
- **§3.2** — `project.pbxproj` sets `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; `AVFoundationAudioWriter.swift:5` is an un-isolated struct (→ MainActor); `TrackDAO.swift:18`/`AlignmentAnchorDAO.swift:13` are synchronous `db.write`. Confirmed High.
- **§5.1** — `NarrationService.swift:80` track id is voice-independent + `save` (upsert); `:58` anchor id is deterministic + `anchorDAO.insert` (throws on dup PK), separate transactions. Confirmed High.
- **§5.2** — `NarrationService.swift:73-74` writes `"<audiobookID>-ch<n>-<voice>.m4a"`; `NarrationExportService.swift:19,24` filters `hasPrefix("narration_<bookID>_")` — prefix never matches. Confirmed High.
- **§5.3 / §5.6** — `KokoroTTSEngine.swift:27-32` inference is comments; `:38` `Task.sleep`; `:46` returns `samples: []`; `loadModel` (`:12`) has zero callers (grep). Benchmark test instantiates with `model=nil` and returns at the no-model guard before the sleep. Verified (demoted to Medium — labeled spike, unreachable).
- **§5.5** — `AudioMarkerStub.swift:14-17` does `removeItem`+`copyItem` only; comment at `:12-13` claims chapter atoms it never writes. Verified Medium.
- **§6.1** — `ModelDownloader.swift:22` hardcoded unpinned `resolve/main` URL; `:46` `unzipItem` into App Support with no integrity/zip-slip guard. Verified Medium (unreachable).
- **§6.2** — `NarrationService.swift:56-63` inserts `.synthesized` into `alignment_anchor`; `CloudKitSyncService.swift:86-89` uploads by `audiobook_id` with no source filter. Verified Low (mechanism real, gated).
- **Dropped:** "AAC output format mismatch" (`AVFoundationAudioWriter.swift:13-46`) — verification found it rests on a misreading of `AVAudioFile`'s `fileFormat` (on-disk, AAC) vs `processingFormat` (in-memory PCM); the code is correct. _REMOVED: false positive._
