# Narration Performance — ORT Tuning + First-Sentence Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** PLAN ONLY — no code was changed in the PR that introduces this file (related narration work was in flight; see the overview doc). This is a night-shift investigation deliverable.

**Goal:** Make on-device Kokoro narration *start* dramatically faster (perceived first-word latency from "whole chapter" → ~1–2 s) and run measurably faster overall, closing the gap with Fox Reader.

**Architecture:** Two independent, stackable changes behind the existing `TTSEngine` seam and `NarrationService` orchestration: (1) tune the ONNX Runtime session (threads + graph optimization + best-effort XNNPACK) — tiny, low-risk; (2) stream playback so chapter 1 begins as soon as a small first segment is rendered, instead of after the whole chapter finalizes.

**Tech Stack:** Swift, `onnxruntime-objc` (ORT 1.24.x), AVFoundation, GRDB, Swift Testing.

## Why it's slow today (root cause, verified)

1. **No streaming — the whole first chapter renders before any audio plays.** `PlayerModel.startNarrationPlayback` awaits `service.renderChapter(...)` for `offset == 0` and only then calls `prepareToPlay(index:0, autoplay:true)` ([PlayerModel+Narration.swift:234-254](EchoCore/ViewModels/PlayerModel+Narration.swift)). `renderChapter` synthesizes every ≤200-char sub-chunk serially and finalizes the ALAC file before returning ([NarrationService.swift:123-243](EchoCore/Services/Narration/NarrationService.swift)). At RTF ≈ 0.5, a 5-minute chapter ≈ 150 s of synthesis before the first word. **This is the dominant cause.**
2. **Bare ORT session options.** `let options = try ORTSessionOptions()` with nothing set ([OnnxKokoroEngine.swift:104](EchoCore/Services/Narration/OnnxKokoroEngine.swift)) — no intra-op thread count, no graph-optimization level, no XNNPACK execution provider. On an A14 (2 performance cores) this leaves CPU latency on the table and likely explains part of Echo's RTF disadvantage vs Fox.

Non-issues (already good — do **not** touch): G2P/vocab/voicepack are cached and loaded once ([KokoroFrontEnd / OnnxKokoroEngine.swift:134-138](EchoCore/Services/Narration/OnnxKokoroEngine.swift)); the session loads once per engine instance; a pre-warm `prepare()` already runs on book open.

## Decisions made while you slept (override freely)

- **Ship ORT tuning first (Phase 1), streaming second (Phase 2).** ORT tuning is ~5 lines in one shared file, output-preserving, and benefits both iOS and macOS immediately. Streaming is the bigger perceived win but touches the playback pipeline, so it lands as its own follow-up PR.
- **Streaming approach = "tiny intro track" (option B), not growing-file streaming (option A).** Echo's resume, read-along anchors, and `Track`-per-chapter model all assume one finalized file per chapter; appending to a live `AVAudioFile` while `AVPlayer` reads it is risky. Splitting chapter 1 into a tiny **intro** track (first 1–2 sentences) + a **rest** track reuses the existing "append track and advance" machinery and the gapless engine, with no growing-file hazard. (See Open Questions if you'd rather do true single-file streaming.)
- **XNNPACK is best-effort.** If `appendExecutionProvider("xnnpack", …)` throws (it may reject some fp16 ops), fall back to the plain CPU session — narration must never brick.
- **Thread count is device-class-aware:** iOS → 2 (A14 perf cores); macOS → a higher constant. Measure 1 vs 2 on the A14 before locking it in.
- **Scope:** Phase 1 = iOS + macOS (shared engine). Phase 2 streaming orchestration = **iOS first** (`PlayerModel+Narration.swift` is `#if os(iOS)`); macOS batch-renders ahead of playback so it is far less latency-sensitive — a macOS streaming follow-up is optional.

## Open questions for Dan
1. **Streaming shape:** OK with the tiny-intro-track approach (B), or do you want true single-file streaming (A)? B is lower-risk and protects the read-along anchor invariants.
2. **First-word target:** warm session + one short sentence at RTF ~0.5 ≈ 1–2 s. Good enough, or should we *pre-synthesize the first sentence at book-open* during the existing pre-warm so tap-to-play is near-instant?
3. **XNNPACK:** was it deliberately left off during the 2026-06-19 A14 spike, or never tried? Phase 1 should A/B it on-device.
4. **Is the pain "first word" or "throughout"?** If playback ever stalls waiting on render mid-chapter, Phase 1 (throughput) is mandatory, not just nice-to-have.

## Global Constraints
- Branch target: **`nightly`** (never `main`). Echo promotion ladder.
- Tests: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`. 16 GB machine — never parallel xcodebuild, never two xcodebuild at once.
- Narration ships on **iOS + macOS only** (not watchOS/Widget). Engine code is `#if os(iOS) || os(macOS)` in `EchoCore`.
- The engine logs RTF per synthesis ([OnnxKokoroEngine.swift:177-179](EchoCore/Services/Narration/OnnxKokoroEngine.swift)) — this is the measurement instrument; keep it.
- This is an architecture/feature change → **doc-sync** ARCHITECTURE.md + CHANGELOG.md (use the `doc-sync` skill) before the PR.

---

## Phase 1 — ORT session tuning (low risk, do first)

### Task 1: Tune ONNX Runtime session options

**Files:**
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift:104` (the `prepare()` task that builds `ORTSessionOptions`)
- Test: `EchoTests/OnnxKokoroEnginePrepareTests.swift` (extend existing)

**Interfaces:**
- Consumes: `ORTSessionOptions` API — `setIntraOpNumThreads(_:)`, `setGraphOptimizationLevel(_:)`, `appendExecutionProvider(_:providerOptions:)` (ORT 1.24.x obj-c).
- Produces: a still-working `prepare()` / `synthesize()` path (same audio output), faster compute.

- [ ] **Step 1: Write the failing test** — assert `prepare()` succeeds and `synthesize` returns non-empty audio *with options applied*, guarding against a typo/XNNPACK rejection bricking the session. Use the existing `init(modelProvider:)` test seam.

```swift
// EchoTests/OnnxKokoroEnginePrepareTests.swift (add)
@Test func tunedSessionStillSynthesizes() async throws {
    let engine = OnnxKokoroEngine(modelProvider: { _ in try TestModel.bundledOrSkip() })
    try await engine.prepare()
    let chunk = try await engine.synthesize("Hello there.", voice: VoiceID("af_heart"))
    #expect(!chunk.samples.isEmpty)
}
```

- [ ] **Step 2: Run it to confirm current behavior** — `make build-tests` then `make test-only FILTER=EchoTests/OnnxKokoroEnginePrepareTests`. (If no bundled model in CI, this test is skipped — note that; the real proof is the on-device RTF log, Step 5.)

- [ ] **Step 3: Apply session options.** Replace the bare options block with (illustrative — adapt to the exact ORT obj-c signatures):

```swift
let options = try ORTSessionOptions()
try options.setGraphOptimizationLevel(.all)
#if os(iOS)
let threads: Int32 = 2          // A14 has 2 performance cores; measure 1 vs 2
#else
let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
#endif
try options.setIntraOpNumThreads(threads)
// Best-effort XNNPACK — must never brick narration.
do {
    try options.appendExecutionProvider(
        "xnnpack", providerOptions: ["intra_op_num_threads": String(threads)])
} catch {
    logger.notice("XNNPACK EP unavailable, using plain CPU: \(error.localizedDescription, privacy: .public)")
}
```

- [ ] **Step 4: Run the test to verify it passes** — same command as Step 2. Expect PASS (or SKIP in CI with no model). Then confirm the full suite is green: `make test`.

- [ ] **Step 5: On-device RTF measurement (Dan, A14).** Run to the iPhone 12 Pro, narrate a chapter, read Console for the `RTF …` line ([OnnxKokoroEngine.swift:177](EchoCore/Services/Narration/OnnxKokoroEngine.swift)). Record baseline (current `main`) vs tuned. Also try `threads = 1` vs `2` and note which wins. **Acceptance: RTF improves and audio is unchanged.**

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/OnnxKokoroEngine.swift EchoTests/OnnxKokoroEnginePrepareTests.swift
git commit -m "perf(narration): tune ONNX session (threads, graph opt, best-effort XNNPACK)"
```

---

## Phase 2 — First-sentence streaming (the big perceived win)

> Land as a **separate PR** after Phase 1 ships and the RTF baseline is measured. Below is the task breakdown; treat code as illustrative.

### Task 2: Add a "first segment ready" callback to chapter rendering

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift` (`renderChapter` — emit after the first sub-chunk is finalized as its own short segment)
- Modify: `EchoCore/Services/Narration/NarrationTextChunker.swift` (cap the very first sub-chunk of chapter 1 to one sentence ≈ ≤120 chars)
- Test: `EchoTests/NarrationTextChunkerTests.swift`, `EchoTests/NarrationServiceTests.swift`

**Interfaces:**
- Consumes: existing `MockTTSEngine` injection in `NarrationServiceTests`.
- Produces: chapter-1 render that yields an **intro segment** (first sentence(s)) before the **rest segment**, with correct anchor time spans and the 0.75 s lead-out pad applied only to the *final* segment.

- [ ] **Step 1 (chunker): failing test** — assert the first piece of a long first block is ≤ the new small-first-chunk cap, and existing invariants still hold (no piece > maxChars, content preserved, sentence-aware split).

```swift
@Test func firstChunkOfChapterIsShortForFastStart() {
    let chunker = NarrationTextChunker()
    let pieces = chunker.split(longParagraph, isChapterStart: true)
    #expect(pieces.first!.count <= 120)
}
```

- [ ] **Step 2:** run → fail (`isChapterStart` param / short-first behavior not present).
- [ ] **Step 3:** implement the short-first-chunk cap (add the `isChapterStart` knob; default false preserves current behavior elsewhere).
- [ ] **Step 4:** run → pass; full chunker suite green.
- [ ] **Step 5 (service): failing test** — with a `MockTTSEngine`, assert `renderChapter` for chapter 1 produces an intro segment whose anchors cover only the first sentence and a rest segment covering the remainder; assert the lead-out pad is on the final segment only.
- [ ] **Step 6:** run → fail.
- [ ] **Step 7:** implement intro/rest segmentation in `renderChapter`.
- [ ] **Step 8:** run → pass; full `NarrationServiceTests` green.
- [ ] **Step 9: Commit** — `git commit -m "feat(narration): render chapter 1 as a short intro segment + rest for fast start"`

### Task 3: Start playback on the intro segment

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift:234-264` (play the intro track as soon as it finalizes; append the rest track via the existing append-and-advance path)
- Test: `EchoTests/NarrationServiceTests.swift` (assert ordering: `prepareToPlay` fires after the *intro* finishes, not after the full chapter) — observe the order of mock synth completions vs the play trigger.

**Interfaces:**
- Consumes: intro/rest segments from Task 2; existing `prepareToPlay(index:autoplay:)` and the look-ahead/backpressure in `NarrationRenderPolicy`.
- Produces: first audio after the intro segment; seamless continuation into the rest track via the gapless engine.

- [ ] **Step 1: failing test** — with injected mocks, assert play is triggered after the intro segment completes and before the rest segment finishes.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** wire intro-first playback; ensure read-along anchors span correctly across the intro/rest seam (no gap, no double-count of the lead-out pad).
- [ ] **Step 4:** run → pass.
- [ ] **Step 5: first-word latency instrumentation** — log delta from `startNarrationPlayback` entry to first audio buffer scheduled. **Acceptance (Dan, A14, warm): < ~2 s.**
- [ ] **Step 6: Commit** — `git commit -m "feat(narration): start playback on the intro segment (first-sentence streaming)"`

### Task 4 (optional, after measurement): pipeline + defer timeline recalc
- Overlap `synthesize(N+1)` with `append(N)` ([NarrationService.swift:134-150](EchoCore/Services/Narration/NarrationService.swift)).
- Move `recalculateTimeline` / `materializeChapter` off the first-audio critical path ([NarrationService.swift:207-228](EchoCore/Services/Narration/NarrationService.swift)).
- Only pursue if Phase 1 + intro-streaming don't fully close the gap.

---

## Self-review notes
- **Spec coverage:** slow-start → Phase 2; slow-overall → Phase 1 (+ Task 4). Both reported symptoms covered.
- **No placeholders:** all file:line concrete; code marked illustrative because the PR ships docs only.
- **Risk:** Phase 1 is output-preserving (graph opt + threads can't change results; XNNPACK guarded). Phase 2 touches playback — gated behind tests asserting anchor/pad correctness across the intro/rest seam.
- **Cross-platform:** Phase 1 lands on iOS+macOS at once (shared engine). Phase 2 is iOS-first by design.
