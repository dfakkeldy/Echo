# Plan — macOS (and iOS) narration "stuck loading models on #7"

Date: 2026-06-19
Author: overnight systematic-debugging session (Claude), hardened by 4 adversarial reviews
Status: PROPOSED — awaiting Dan's go / no-go
Branch suggestion: `fix/narration-duration-model-prune`

> **v2** — incorporates four adversarial reviews. The big change from v1: a
> previously-missed **error-taxonomy blocker** is now the FIRST step, because
> without it the t256 cap would turn today's latent failure into a more frequent
> one. Read §4.0 first.

---

## 1. TL;DR

The macOS batch narration sits forever on "Loading voice models… 7 of 19". It is
**not** a crash, deadlock, or download failure. The first-run CoreML *compile* of
the fixed-shape Kokoro model set is the bottleneck, and within that set the cost
is almost entirely **three duration models that can never actually be used**.

- 12 of the 19 models (f0ntrain, decoder_pre, decoder_har_post) compile **+** load
  in **< 2 s each** (measured, clean run). They are not the problem.
- The 7 **duration** models are. Their compile time explodes with token length:
  t256 ≈ 50 s, **t320 ≈ 3 min, t384 ≈ 6 min, t512 ≈ 20 min** (from the app's own
  on-disk compiled-cache mtimes).
- The narration chunker caps every synthesis call at **200 characters**. Normal
  prose → ≤ ~220 tokens; `selectDurationChoice` therefore **never selects above
  t256** for ordinary text. **t320 / t384 / t512 are ~29 min of compile for models
  the normal path never runs** (95% of all duration-compile time).

**Primary fix:** stop loading duration models larger than t256, using the
already-built, already-unit-tested `discoverDurationChoices(maxDurationTokenLength:)`
filter — currently unwired in production. First-run model prepare drops from
**~30 min → ~1.6 min**, fixes existing installs with **no re-download**.

**But** the cap has a sharp edge the v1 plan got wrong: when a sub-chunk *does*
exceed the largest loaded duration model, the pipeline throws
`PipelineError.inputTooLong`, and **nothing in `NarrationService` catches that
error type today** — it fails the whole chapter. Number-heavy non-fiction
(financial figures, page-reference lists, statistics) realistically produces
>256-token chunks (measured: 9/73 chunks in a number-heavy corpus). So the cap
ships **only together with** (a) routing that error into the existing skip path and
(b) a token-aware re-split so those chunks are narrated, not dropped. This is
§4.0 + §4.4 and is non-negotiable.

---

## 2. Evidence (measured this session)

### 2.1 Disk forensics — the app's persisted compile cache
`…/Application Support/Narration/Models/kokoro-fixed-v5/`
- Download **complete** (`.complete` sentinel + 20 packages + per-package markers).
- `compiled/` holds **exactly the 7 duration `.mlmodelc` (t32…t512) and nothing else.**
- Per-model compile time from cache mtimes: t32 ~6s, t64 ~6s, t128 ~22s, t256 ~50s,
  t320 ~3.3min, t384 ~6min, **t512 ~19.5min**.
- **Why only duration in `compiled/`?** The populating run reached t512 (model #7)
  at 23:51 and the process ended before model #8 (f0ntrain) — i.e. the user quit
  during/after the ~20-min t512 wait. Consistent with "stuck on #7". (It is *not*,
  by itself, evidence of a non-duration cache-write bug — see §4.5 for why we still
  harden the cache.)

### 2.2 Benchmark — the other 12 models (clean, crash-isolated harness)
```
f0ntrain t120/280/400/600 : compile 0.14-0.28s, load 0.25-0.36s   [gpu]
decoder_pre 3/7/10/15s     : compile 0.13-0.15s, load 1.6-2.2s     [ane]
decoder_har_post 3/7/10/15s: compile 0.23-0.25s, load 0.50-0.54s   [gpu]
=> all 12 ≈ 13 s total. (My v1 hypothesis "stuck on #8 = f0ntrain" was WRONG:
   f0ntrain_t120 compiles in 182 ms. The slow models are strictly the big
   duration ones, #4-#7 = t256/t320/t384/t512.)
```

### 2.3 Chunk-token measurement — real Misaki G2P, pure-Swift tool, WITH normalizer
Ran `NarrationTextChunker.split(maxChars:200)` → thousands-separator strip →
`EnglishG2P` → `KokoroPhonemeVocab` token count (one id per IPA char incl. stress/
length marks + inter-word spaces + BOS/EOS):
```
realistic prose only:        median 178, p95 216, max 220        → fits t256
+ number-heavy non-fiction:  median 183, p95 336, 9/73 chunks > 256 tokens
pathological all-digit:      up to 1151 tokens (exceeds even t512)
```
**Conclusions:** (1) ordinary prose never needs > t256. (2) number-heavy real text
*can* exceed 256 — so re-split is required for losslessness. (3) nothing, not even
t512, covers the pathological tail — so re-split is required *regardless of cap*,
which is itself the argument for the cheapest safe cap (256).

### 2.4 Not a crash; system was thrashing
No crash/jetsam reports. During repro, swap was **11.1 GB / 12.3 GB used** — this
16 GB Mac thrashes, turning the (already minutes-long) duration compile into an
indistinguishable-from-hung experience.

---

### 2.5 Mechanism — why DURATION models specifically explode (confirmed from the proto)
`strings` on the compiled `model.mlmodel`:
- **duration t256:** `lstm` ×7728, `attention` ×584, `matmul` ×132, `LayerNorm` ×34, over
  `input_ids`/`attention_mask` — an **LSTM + attention stack over the token sequence**.
  LSTM unrolls over the token dimension and attention is **O(n²)** in sequence length, so
  compile/load cost is super-linear in token count (t512 ≈ 512-step unroll + 512×512
  attention ≈ 4× t256's work). This is the explosion.
- **f0ntrain t600:** `conv` ×60, `conv1/conv2` ×36, `lstm` ×5 — **convolutional over
  frames**, flat-cheap to compile regardless of frame count (hence ~150 ms even at t600).

This both explains the measured times *and* reinforces the fix: capping the token
dimension at 256 caps attention at 256² instead of 512².

## 3. Root cause (one sentence)

`KokoroPipeline.init` eagerly compiles every duration `.mlpackage` on disk
(t32…t512), but the 200-char chunker means ordinary text never selects above t256,
so the app burns ~29 minutes compiling three models it won't run before narration
can begin — and a latent error-handling gap means the genuinely-too-long chunks it
*does* hit fail the whole chapter rather than degrading gracefully.

---

## 4. The fix

Land the steps **in this order**. §4.0 and §4.4 must ship *with or before* the cap
(§4.1–4.3); shipping the cap alone is a regression.

### 4.0 — PREREQUISITE: route `PipelineError.inputTooLong` into the skip path
**Bug (verified):** `KokoroFixedShapeEngine.synthesize` (`KokoroFixedShapeEngine.swift:117`)
propagates `KokoroPipeline.PipelineError.inputTooLong` (`KokoroPipeline.swift:447`)
**raw**. `NarrationService.isLengthCapError` (`NarrationService.swift:297-310`) only
recognizes `NarrationError.lengthCapExceeded` and (iOS-only) `KokoroAneError`, so the
catch at `NarrationService.swift:146` does **not** fire. The throw escapes
`renderChapter`:
- iOS (`PlayerModel+Narration.swift:306`) → `narrationPlaybackState.fail(...)` (narration aborts).
- macOS (`Echo macOS/Services/MacBatchProcessingService.swift:348-365`) → fresh-engine retry → `skipped += 1` (whole chapter lost).

This is a **pre-existing latent bug** (a >512-token block fails a chapter *today*).
Fix it first, as its own commit, so it's testable independently of the cap:

**Translate at the engine seam** (cleanest — keeps `NarrationService` decoupled from
the package's error type). In `KokoroFixedShapeEngine.synthesize`, wrap the pipeline call:
```swift
do {
    let result = try pipeline.synthesize(inputIds: inputs.ids, attentionMask: inputs.attentionMask, refS: inputs.refS, speed: 1.0)
    return TTSChunk(samples: result.audio, sampleRate: 24_000, duration: Double(result.audio.count) / 24_000)
} catch let e as PipelineError {
    if case .inputTooLong = e { throw NarrationError.lengthCapExceeded }
    throw e
}
```
Now the existing, tested skip path handles it → graceful degradation on both platforms.
**Test (two parts — a mock can't emit a package error, don't pretend it can):**
(i) a **KokoroPipeline package test** asserting `selectDurationChoice` over-cap throws
`PipelineError.inputTooLong` (the thing being translated); (ii) keep/extend the existing
`NarrationService` test that feeds `NarrationError.lengthCapExceeded` (already green at
`NarrationServiceTests` ~:225) and asserts the chapter survives. `MockTTSEngine` lives in
the Echo test target and must NOT `import KokoroPipeline`, so it tests the *translated*
error, not the raw one.

### 4.1 — Plumb a max-duration-token cap through the pipeline init
**File:** `ThirdParty/KokoroPipeline/Sources/KokoroPipeline/KokoroPipeline.swift`
`discoverDurationChoices` already has a tested `maxDurationTokenLength: Int?` filter
(`DurationChoiceTests.testDurationChoicesCanBeCappedForProductionWorkers`). The
public `init` (~line 217) calls it without the cap (line 225). Add a defaulted param:
```swift
public init(
    modelsDirectory: URL,
    compiledModelsDirectory: URL? = nil,
    buckets: [Int] = PipelineConstants.defaultBuckets,
    linearWeights: [Float],
    linearBias: Float,
    maxDurationTokenLength: Int? = nil,          // NEW (defaulted → source-compatible)
    compileProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
) throws {
    let durationChoices = Self.discoverDurationChoices(
        modelsDirectory: modelsDirectory,
        maxDurationTokenLength: maxDurationTokenLength)   // pass through
    ...
```
`total` (compileProgress denominator) derives from `durationChoices.count`, so it
self-corrects. Only one app caller; defaulted param keeps `kokoro-bench`/ios-bench
and the `useExactDurationModels` discovery branch source-compatible (the filter also
applies to exact packages — `KokoroPipeline.swift:381`).

> **Two-constant trap:** there are **two** independent copies of the token-size list.
> `PipelineConstants.durationTokenSizes` (`KokoroPipeline.swift:64`) drives *discovery*
> and stays `[32…512]`. `NarrationModelStore.durationTokenSizes` (§4.3) drives the
> *download* set. Runtime pruning is done by the **cap param**, not by editing either
> list. Do not try to "keep them in lockstep" — they have different jobs.

### 4.2 — Pass the cap from the engine
**File:** `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift` (~line 96)
```swift
let built = try KokoroPipeline(
    modelsDirectory: dir, compiledModelsDirectory: compiledDir,
    buckets: NarrationModelStore.keptBucketSeconds,
    linearWeights: NarrationModelStore.hnsfLinearWeights,
    linearBias: NarrationModelStore.hnsfLinearBias,
    maxDurationTokenLength: NarrationModelStore.maxDurationTokens,   // NEW (= 256)
    compileProgress: { done, total in fan.emit(.compilingModels(done: done, total: total)) })
```
Add to `NarrationModelStore`:
```swift
/// Largest duration token-bucket we compile/load. The chunker caps synthesis input
/// at NarrationTextChunker's 200 chars → ≤~220 tokens for prose (measured 2026-06-19).
/// Models above this are ~29 min of first-run CoreML compile the prose path never
/// runs. Number-dense chunks that DO exceed it are re-split by the engine (§4.4), so
/// this cap never drops content. Engine self-splits to keep every synth call ≤ this.
static let maxDurationTokens = 256
```

### 4.3 — Stop shipping the dead models to new installs
**File:** `EchoCore/Services/Narration/NarrationModelStore.swift` (~line 40)
```swift
// Was: [32, 64, 128, 256, 320, 384, 512]
private static let durationTokenSizes: [Int] = [32, 64, 128, 256]
```
Shrinks first-launch download. Existing installs keep the big packages on disk but
§4.1/4.2's cap **ignores** them → fix lands with no re-download. The `.complete`
sentinel's count is written but **never read** (`NarrationModelStore.swift:92` fast-paths
on `fileExists(.complete)` only), so existing installs neither re-download nor
mismatch. **Do NOT bump `modelSubdir`** ("kokoro-fixed-v5") — that would force a
full ~850 MB re-download.
**Update test:** `EchoTests/NarrationModelStoreTests.swift:37-40` asserts t512 is
present — flip it to assert t320/t384/t512 are **absent** and t256 present.

### 4.4 — Make the engine self-split over-cap input (token-aware, lossless)
**Goal:** keep every `synthesize` call ≤ `maxDurationTokens` so realistic number-heavy
text is *narrated* (re-split), never dropped, and `inputTooLong` becomes
belt-and-suspenders that essentially never fires.

**Where:** `KokoroFixedShapeEngine.synthesize`. It already builds `inputs` via
`PipelineInputs.make(text:voice:)`, which computes `ids` — i.e. the engine **knows
the token count** and has the G2P. So it can guarantee the bound itself:
```
synthesize(text):
    inputs = PipelineInputs.make(text)
    if inputs.ids.count <= maxDurationTokens: return pipeline.synthesize(inputs)
    // too long → split text and concatenate audio (one TTSChunk, summed duration)
    let halves = NarrationTextChunker.split(text, maxChars: max(40, text.count/2))
    if halves.count < 2 { /* single indivisible token */ throw NarrationError.lengthCapExceeded }
    var samples: [Float] = []
    var producedAny = false
    for piece in halves {
        do { samples += try await synthesize(piece, voice).samples; producedAny = true }  // recursion re-checks tokens
        catch NarrationError.lengthCapExceeded { continue }  // skip ONLY the indivisible piece, keep siblings
    }
    if !producedAny { throw NarrationError.lengthCapExceeded }  // nothing salvageable → let the caller skip
    return TTSChunk(samples, 24_000, …)
```
> **Partial-loss guard (review fix):** without the per-piece `catch`, one indivisible
> floor-throw would discard *all* already-synthesized sibling samples for the block —
> worse than the non-split path, which skips only the bad sub-chunk. The per-piece
> catch matches that loss-tolerance: keep everything that synthesized, drop only the
> genuinely-impossible piece, and surface `lengthCapExceeded` only if the whole chunk
> produced nothing.
- **Token-aware termination (critical):** recursion re-runs `PipelineInputs.make` on
  each piece, so it splits until each piece is *actually* ≤256 tokens — a char floor
  alone cannot bound tokens (40 chars of digits > 256 tokens). The floor only stops
  infinite recursion on a genuinely indivisible single token, which then throws
  `lengthCapExceeded` → skipped + logged (vanishingly rare; pathological digit runs).
- **Read-along is unaffected:** the split returns ONE `TTSChunk` with summed samples,
  so `NarrationService`'s per-block `blockDuration` accumulator and single per-block
  anchor (`NarrationService.swift:143,156`) see exactly what they would for an
  un-split chunk. No new anchors, no cross-track timing change.
- `maxDurationTokens` must be visible to the engine — it already passes it to the
  pipeline (§4.2); store it on the actor too.

**Algorithm validated (2026-06-19, real Misaki G2P, pure-Swift simulation):** ran this
exact recursive self-split over the §2.3 corpus including the 1151-token all-digit
pathological string. Result: **worst leaf after split = 238 tokens ≤ 256, recursion
terminates, 0 pieces hit the indivisible floor (zero content lost)**, ~24 extra synth
calls across 9 over-cap chunks. The token-aware bound holds even on adversarial input.

(Alternative if engine self-split proves awkward: do the re-split in
`NarrationService`'s `catch` after §4.0 routes the error in — but it must re-tokenize
to bound recursion, which means giving `NarrationService` G2P access; the engine
already has it, so engine-side is cleaner.)

### 4.5 — Cache: make it self-diagnosing AND hardened (don't *assert* it's correct)
**File:** `ThirdParty/KokoroPipeline/Sources/KokoroPipeline/KokoroPipeline.swift`
`ensureCompiledModel` (~line 495).
- Log cache **HIT** vs **compile** at `.notice` so the next real run shows whether
  relaunch recompiles (settles the unproven 00:15 question).
- The catch-all `catch { return compiled }` (`KokoroPipeline.swift:508-510`) silently
  returns the temp URL on **any** move/create failure → never caches → recompiles
  every launch. Make that path **loud** (`.error` "compile-cache WRITE FAILED \(name): \(error)")
  so a real cache-write failure is visible instead of looking like an environmental
  fluke. (The unit test stubs compile into the *same* dir as the cache, so `moveItem`
  is intra-dir and can't fail — it proves nothing about the real `NSTemporaryDirectory()
  → Application Support` move. For a sandboxed app both live under the same container
  volume, so the move should succeed, but the logging removes the guesswork.)
- If `MLModel(contentsOf: cached)` later **throws** (e.g. an OS upgrade invalidated a
  cached `.mlmodelc`), delete the stale entry and recompile once rather than hard-fail.
- **Add a test** where `compile` returns a URL under a *different* parent than `cacheDir`
  so the real cross-directory move is exercised.

### 4.6 — Cancellability of the compile (cheap, do it)
The compile loop in `KokoroPipeline.init` (~lines 263-308) has **no**
`Task.checkCancellation()`, and `MLModel.compileModel` is an uninterruptible blocking
call. So quitting/cancelling during a compile is ignored until the current model
finishes. With the prune the worst single model is ~50 s (t256), so add
`try Task.checkCancellation()` between models in the loop — a cancel then lands within
one model instead of (pre-prune) up to 20 min. (init isn't `async`; either make the
loop check via a passed-in `@Sendable () -> Bool isCancelled` from the engine's Task,
or check `Task.isCancelled` if the call tree allows. Keep it simple.)

---

## 5. Risks & mitigations (v2)

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Over-256 chunk fails the chapter | **Real, not pathological** (9/73 number-heavy chunks) | §4.0 routes the error to skip; §4.4 re-splits so it's narrated, not skipped. Ship together. |
| Re-split infinite-loops / drops content | Low | Token-aware recursion (§4.4) splits until ≤256 tokens; char floor only guards a single indivisible token → log+skip. |
| Cache silently recompiles every launch | Unknown (unproven) | §4.5 loud-logs write failures + HIT/MISS; prune makes a full recompile only ~1.6 min anyway. |
| Cancel/quit appears to hang during compile | Was up to 20 min | §4.6 + prune → lands within ~50 s. |
| Existing rendered books change audio | None | ≤256-token selection unchanged; only never-selected models removed. |
| Memory thrash | — | Prune helps **marginally** (duration models are cheap at load); the real thrash driver is the kept decoder/generator/f0ntrain set + 11 GB swap baseline. Don't oversell prune as a memory fix; the memory lever is the §7 lazy backup. |

---

## 6. Test plan

1. **§4.0 regression:** surface `PipelineError.inputTooLong` (real type) through the
   engine and assert `renderChapter` survives on iOS and macOS paths.
2. **Init-level cap test:** build `KokoroPipeline` against a fixture dir of t32…t512
   with `maxDurationTokenLength: 256`; assert 4 duration models load, not 7.
3. **Token-budget regression (EchoTests, has G2P):** run
   chunker → `KokoroG2P` → `KokoroPhonemeVocab` over a fixed corpus (prose + the
   number-heavy + adversarial sets from this session) and assert the *re-split engine*
   keeps every emitted synth-call ≤ `maxDurationTokens`, and that total content is
   preserved (no dropped words for non-pathological inputs).
4. **NarrationModelStoreTests** updated for the pruned download set (§4.3).
5. **On-device acceptance (Dan):** "Narrate EPUB…" on Mac completes prepare in ~1–2 min
   (was: never); narration proceeds; Console shows `compile-cache HIT` on 2nd launch.
   Try a number-heavy chapter (stats/financial) and confirm it narrates fully.
6. `make build-tests` once, then `make test-only FILTER=EchoTests/Narration*` + the
   KokoroPipeline package tests. One xcodebuild at a time (16 GB machine).

---

## 7. Backup plan (measurement-gated, not now)

If, after the prune, **cached relaunch** time-to-first-audio exceeds a stated budget
(say >20 s), escalate to **lazy / on-demand per-bucket model loading**: `KokoroPipeline.init`
loads only the first chunk's bucket (1 duration + 1 f0ntrain + 1 decoder_pre + 1 generator),
starts narrating, and compiles/loads remaining buckets lazily/in background. A single
synth needs exactly one bucket (traced through `KokoroSynthesisExecutor`), so the
premise is sound. **Effort: L** — the four model stores are immutable `let` dicts
populated in `init`; the four `KokoroModelProvider` accessors are synchronous `throws`;
making them compile-on-demand needs a lock or actor (rippling `async` through the
synchronous executor + protocol that `kokoro-bench` also implements). Real concurrency
surgery across a shared package boundary to save ~10–15 s of one-time-per-launch load —
do it only if a measurement demands it. (Smaller sub-backup: load duration models
`.cpuOnly` — duration is the cheapest inference stage and CPU load-specialization was
faster in the bench.)

**Rejected:** ship precompiled `.mlmodelc` (load-time specialization is *also* slow for
duration; `.mlmodelc` is OS-version fragile to ship; the on-device compile cache already
persists). Single flexible-shape duration model (re-opens the dynamic-shape A14 BNNS
wedge the fixed-shape design closed).

---

## 8. Commit sequence

1. `fix(narration): route PipelineError.inputTooLong into the length-cap skip path` (§4.0 + test) — independently correct, fixes a latent chapter-failure bug.
2. `feat(narration): self-split over-cap synthesis input so dense chunks narrate` (§4.4 + test).
3. `perf(narration): cap loaded duration models at t256 (≈30 min → ≈1.6 min first-run)` (§4.1, §4.2, §4.3 + tests).
4. `fix(narration): loud compile-cache write-failure logging + stale-cache recompile` (§4.5).
5. `fix(narration): make model compile loop cancellable` (§4.6).

(1 and 2 before 3. 4 and 5 independent.)

---

## 9. Docs to update (CLAUDE.md doc-sync rule)
- `ARCHITECTURE.md` narration section: duration-model cap + chunker↔cap coupling + engine self-split.
- `CHANGELOG.md`: the commits above.
- Memory `narration-feature.md`: root cause + fix + the error-taxonomy latent bug.

---

## Appendix — adversarial review outcomes
4 independent reviewers. 3× REVISE converged on the §4.0 error-taxonomy blocker
(none of which v1 had); 1× PLAN-IS-RIGHT confirmed prune-over-lazy and the ~30 min→
~1.6 min math (v1 said "~33 min" — a ~10% round-up; corrected here). All cross-target
surfaces confirmed clean (watchOS/Widget untouched; m4b export stitches rendered files,
never calls the engine; no re-download for existing installs).
