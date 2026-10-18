<!--
Decision brief produced 2026-06-19 by a 30-agent fan-out → adversarial-verify → synthesize workflow
(wf_8bd5b9ce-e28): 20 supported, 4 refuted, 0 unverifiable. Trigger: the fixed-shape CoreML engine
took ~20 min of first-run on-device AOT compile on an A14 (Dan killed it; "Fox is almost instant").
This brief SUPERSEDES the 2026-06-19 shrink/delivery brief — the pivot obsoletes that whole plan.
Confidence tags are the synthesis agent's. The pivot is gated on an on-device A14 RTF spike (§7.1).
-->

# Recommendation: Pivot Echo's Kokoro TTS off AOT-compiled CoreML to ONNX Runtime (CPU EP)

## 1. Bottom line

**Pivot: YES.** [high] The fixed-shape CoreML path provably cannot deliver Fox-like instant first-run on A14 — an architectural ceiling, not a tuning problem (§2).

**Recommended runtime: ONNX Runtime (CPU execution provider), not MLX.** [high] Ranked ONNX-CPU > single-small-CoreML > MLX. ONNX has a clean license stack, an official SPM package, a model that maps 1:1 onto Echo's existing input-assembly code, and it deletes ~731 MB of model machinery for one ~163 MB file. MLX is viable but weaker — A14-unvalidated, re-imposes a heavy native dependency Echo deliberately deleted, wrong tool to bet the floor device on.

**Single biggest risk: A14 CPU throughput (RTF), not memory.** [high] Honest phone RTF ≈ 0.8 (NimbleEdge: ~8s to synth a 10s clip on recent smartphones); A14 is slower. So a full ≤200-char (~15s) chunk is *several seconds* — you cannot whole-chunk-then-start; you must **stream the first short sentence** for a ~2–4s first word. If a real A14 spike shows CPU-EP RTF materially below ~0.7–0.8 even on a single short sentence, fall back to MLX (GPU/Metal, ~3.3× RT warm on A15 — but unmeasured cold-start + dependency cost).

**Expected first-word latency on A14:** ~1s ONNX session-load (graph interpretation, no Espresso compile) + first-clause synth → budget **~2–4s** [medium], vs the ~1.6-min first-run floor the CoreML path bottoms out at.

**Correction (reshapes the recommendation):** the "memory is the REAL A14 risk / OOMs on a 4 GB iPhone 12 Pro" framing is **refuted** — the **12 Pro has 6 GB** (only the non-Pro 12/12 mini are 4 GB) [high]. The ~786–837 MB resident figures describe *sherpa-onnx on iPhone 15* — a confirm-it's-fine target, not a kill switch. The remaining A14 blocker is compute/compile, not memory (memory half already handled via stream-to-sink). **→ The MLX memory gate is moot; the binding gate is RTF.**

## 2. Why the current CoreML path can't be instant on A14 — NOT salvageable [high]

Four levers, each fails:
1. **The O(n²) compile is the LSTM+attention duration predictor.** `strings` on the t256 spec: `lstm`×7728 + `attention`×584. Compile scales with op count (architecture), not a setting. On-device mtimes: each doubling ~triples compile (t32→t64=5s, t64→t128=14s, t128→t256=47s on M-series; A14 slower). The 20-min headline is upper buckets the prose path never selects.
2. **Pre-compiled `.mlmodelc` doesn't escape it.** Instantiation triggers backend device specialization ("seconds or even minutes"), hardware/OS-specific, can't be precomputed off-device. First load still pays; Echo even discards the cache on OS upgrade.
3. **Background/parallel compile only hides it.** `MLModel.compileModel` is an uninterruptible, CPU-bound, minutes-long blocking call — pre-warm makes the *second* launch fast, never the first.
4. **Pruning is maxed out.** Already caps at t256 + prunes buckets → ~30 min down to ~1.6 min. The duration LSTM is load-bearing (drives the alignment matrix) and can't be removed. ~1.6 min is good engineering and still 2 orders of magnitude off Fox.

**Verdict: the gap is the runtime, not the model.** The only escape from per-length AOT graph materialization is a graph-interpreted (ONNX) or Metal-JIT (MLX) runtime with no Espresso step. CoreML's genuine value is second-run (cache HIT → seconds); it can never win first-run.

## 3. ONNX Runtime on A14

- **Load:** no Espresso/AOT compile; CPU graph optimizations at session-create (seconds; serializable via `optimized_model_filepath`). ~1s session-load. *The structural win.* [high]
- **Crash avoidance:** ORT's CoreML EP can't run Kokoro (dynamic-shape failure → CPU fallback), so a Kokoro-ORT engine runs on CPU **by construction** — physically can't hit the ANE conv→BNNS trap. **Ship CPU-EP-only on the A14 floor**; CoreML EP is at most an A15+ perf experiment, never default. [high/medium]
- **Model size:** evaluate **`model_fp16.onnx` (163 MB) first**; fp32 (326 MB) = quality ceiling. **Skip q8/int8.** [high]
- **RTF soft spot:** int8/q8 is a **TRAP on iPhone — ~2× SLOWER than fp32** (sherpa-onnx #2374, iPhone 15: fp32 19.41s vs int8 39.13s; ARM lacks the int8 SIMD throughput that wins on x86). Honest phone RTF ≈ 0.8. [high/medium]
- **Streaming hides it only for the first short sentence** (3–6 word clause + ~1s load → ~2–4s); whole-chunk-then-play feels slow. Echo already chunks ≤200 chars → this is a streaming-granularity change, not new infra. [medium]
- **License:** clean into GPL-3.0 (ORT = MIT, sherpa = Apache, Kokoro-ONNX model = Apache). Echo sidesteps sherpa's bundled espeak-ng (GPL) by supplying its own MisakiSwift G2P. [high]
- **Integration:** `onnxruntime-swift-package-manager` (MIT, SPM, v1.24.2, iOS 16 floor). `ORTEnv`/`ORTSession`/`ORTValue` callable from Swift. [high]

## 4. MLX on A14 — viable but not recommended

- **OOM scare refuted at the root** (12 Pro = 6 GB; the claim is a single biased competitor README about a 30s clip Echo never produces). With ≤15s chunks on 6 GB, OOM unlikely (unmeasured on A14). [high/medium]
- **No-compile is real but conditional** — only on the prebuilt-metallib default; `MLX_METAL_JIT` compiles kernels on first use (30–60s). [medium]
- **Fatal gap:** no A14 cold-start/first-audio number anywhere (only iPhone 13 Pro/A15 warm ~3.3× RT). [high]
- **Dependency-math corrections (vs original framing):** mlx-swift sim bug #341 **FIXED in 0.30.6+** (no shim needed); no prebuilt 120 MB metallib (vendors ~12 MB `.metal` compiled at build); issue #121 **CLOSED**; license MIT. [high]
- **Net:** re-adds a heavy native GPU-shader dependency Echo deleted 2026-06-18 + unmeasured A14 cold-start. **MLX = fallback if the ONNX-CPU spike shows unacceptable RTF, not first choice.** [high]

## 5. What Fox / Ghost most plausibly use (ranked, honest)

1. **ONNX Runtime CPU — most defensible** (interpreted graph, ~1s load, A14-proven via sherpa-onnx, off-ANE, 86–163 MB models matching "compact model on first use"). Fox's profile fits — but **Fox's exact stack is genuinely unknowable.** [medium]
2. A single small CoreML model that specializes in seconds (keeps ANE perf; first-run still seconds; re-introduces A14 ANE/BNNS risk). [medium]
3. MLX/Metal — weakest fit for the competitors (iOS-18-gated, A14-unvalidated). [medium]

**Ghost Reader is NOT evidence for the non-CoreML hypothesis** [high] — its "CPU-only inference" + "Pocket TTS" sibling fingerprint matches **FluidAudio** (CoreML, ANE-first, `.cpuAndGPU` bypass). Don't cite Ghost as ONNX evidence; don't claim certainty about Fox in user-facing copy.

## 6. The pivot plan — `OnnxKokoroEngine: TTSEngine`

**One-line factory swap + one new file.** `TTSEngine` needs `prepare()`, `prepare(progress:)`, `synthesize(_:voice:) async throws -> TTSChunk` (mono Float32). `NarrationEngineFactory.make()` is the sole construction site; `NarrationService` consumes only `synthesize(subText, voice:)` per ≤200-char sub-chunk → 24 kHz sink (matches Kokoro ONNX output, no resample). [high]

**Reused verbatim:** MisakiSwift G2P + `KokoroPhonemeVocab` (same IPA + int token IDs 0..177); `KokoroVoicePack` + the `af_heart.f32` asset (ONNX voices are flat little-endian Float32 `(510,1,256)` indexed by token length — byte-identical to Echo's resource + selection); `PipelineInputs.make` front-half (g2p → ids → refS), chunking, streaming, ProgressFanOut, `TTSChunk`/`VoiceID`. [high]

**Thrown away:** the entire vendored `ThirdParty/KokoroPipeline` (CoreML orchestrator + Swift DSP: KokoroPipeline, KokoroSynthesisExecutor, HarmonicSource, BucketSelector, WaveformPostProcess, PcmJoiner, MLMultiArrayHelpers, bucket geometry, hn-nsf weights, `ensureCompiledModel`). The single `.onnx` graph contains duration, F0/N, decoder-pre, hn-nsf, and generator internally. **This is what kills the 20-min compile: no `MLModel.compileModel`, no Espresso, no ANE.** [high]

**Obsoletes the 731 MB shrink / Background-Assets plan** — the 17-package set, the recursive HF tree walk, the prune lists, the per-package markers all collapse to **one `model_fp16.onnx` download (163 MB).** [high]

**Engine shape** (actor, mirror `KokoroFixedShapeEngine`):
- `prepare(progress:)`: download `model_fp16.onnx` (`.downloadingModels`), then `ORTSession(...)` (one `.compilingModels(1,1)→.ready`; no per-model compile).
- `synthesize`: reuse `PipelineInputs.make`, **widen token IDs Int32→Int64**; build 3 ORTValues — `input_ids [1,n] int64`, `style [1,256] float32`, `speed [1] float32`; `session.run`; output → `[Float]` → `TTSChunk(sampleRate: 24_000)`. Tokens wrap `[0, *tokens, 0]` (matches Echo's BOS/EOS = 0). **Match the export contract** — some exports name the input `tokens` and take `speed` int32.

**Model + voice:** `onnx-community/Kokoro-82M-v1.0-ONNX` (Apache): `model_fp16.onnx` (163 MB, first), `model.onnx` (326 MB, ceiling); `af_heart.bin` (or reuse Echo's `af_heart.f32`, identical format). [high]

**renderVersion 5 → 6 + new subdir** (`kokoro-onnx-v6`) — different acoustic model → old audio re-renders, old CoreML `.mlmodelc` subtree abandoned. [high]

**Reversibility:** keep `KokoroFixedShapeEngine` + KokoroPipeline in-tree behind the factory until the A14 gate passes (mirror how FluidAudio was kept for the fixed-shape swap); delete in cleanup only after.

**Effort:** new `OnnxKokoroEngine.swift` + SPM dep + factory one-liner + `NarrationModelStore` collapse to single-file download + renderVersion bump + first-sentence streaming granularity. G2P/vocab/voice/chunking/streaming untouched; deleting KokoroPipeline is net-negative LOC. **~a few focused days to a working spike; the gate is the device measurement, not the code.** [medium]

## 7. Open questions / on-device spike

1. **A14 CPU-EP RTF for `model_fp16.onnx`** — the single make-or-break number. No public A14 datapoint exists. [high]
2. **First-sentence-streamed time-to-first-word on A14** — does it land under ~4s? [medium]
3. **Peak resident memory on the 6 GB A14 with WhisperKit concurrent** — confirm-it's-fine, not a kill switch. [medium]
4. **Exact ONNX export I/O contract** (`input_ids` vs `tokens`; `speed` int32 vs float32) — confirm against the shipped file before wiring. [high]
5. **fp16 vs fp32 quality + speed on A14.** [medium]
6. **Fox's runtime stays unknowable** — the pivot is justified by the structural argument + the clean ONNX fit, not by reverse-engineering Fox. [high]

**Gate:** first word < ~4s AND no jetsam on a real iPhone 12 Pro. If RTF unacceptable even streamed → evaluate MLX (§4).

**Doc-sync (when the gate resolves):** update `ARCHITECTURE.md`, the archived `CODE_AUDIT_NARRATION.md` notice if needed, the narration plans, and the repo-local narration remediation map; the shrink/delivery brief is superseded by this one. Do not use this as an instruction to edit external memory stores.
