<!--
Research brief produced 2026-06-19 by a 30-agent fan-out → adversarial-verify → synthesize
workflow (wf_cd013376-43f): 16 claims supported, 8 refuted, 0 unverifiable. Trigger: the owner
confirmed competitor Fox Reader runs Kokoro TTS flawlessly on his iPhone 12 Pro (A14), contradicting
the long-standing "A14 is a hardware crux" framing. Captured here because the workflow output file is
ephemeral. Confidence tags are the synthesis agent's; treat [med]/[low] as leads, not facts.
-->

# Echo A14 Kokoro + Streaming-Start Research Brief

## 1. Bottom line

A14 Kokoro is a **software-routing problem, not a silicon limit** [confidence: high]. Two shipping closed-source apps (Fox Reader, Ghost Reader AI — the latter *explicitly* requires "iPhone 12 / A14 or later") run Kokoro-82M on A14 fine, and the owner confirmed Fox Reader on his own iPhone 12 Pro. Echo's old crash was a **runtime BNNS trap (EXC_BREAKPOINT inside `BNNSGraphContextExecute_v2`)** on FluidAudio's *dynamic-shape, palettized* vocoder running the `ane-tail-gpu` split — long inputs produced a large variable tensor that fell off the ANE into BNNS, which trapped; it is **NOT** a compile-time `ANECCompile() FAILED`, and Echo's own audit says explicitly "it is NOT a compute-unit routing bug" [confidence: high]. The evidence **strongly supports the fixed-shape pivot**: replacing the asset with a bucketed, non-palettized CoreML decoder (`mattmireles/kokoro-coreml`) eliminates the per-length AOT re-specialization that is the documented throw site, and that engine lists iPhone 12 Pro as a *tested* device [confidence: high]. The one remaining gate is honest: no public source measures *Echo's* new engine on A14, so the M1 Pro bench result must still be reproduced on-device before declaring victory [confidence: high].

## 2. How Kokoro runs on iOS A14 — the viable routings

Every serious implementer converges on the same insight: keep variable-length / LSTM / phase-accumulation work **off the ANE**, and put only **fixed-shape dense convolution** on it.

| Path | Vocoder runs on | A14? | Avoids BNNS trap? | Notes |
|---|---|---|---|---|
| **Fixed-shape bucketed CoreML** (`mattmireles/kokoro-coreml` — Echo's new engine) | Staged: F0/Noise + Decoder-Pre + Generator on ANE; hn-NSF harmonic source in Swift/Accelerate (off-ANE); duration on CPU/GPU | **Yes — tested on iPhone 12 Pro** | **Yes** — static fp16 graphs, EnumeratedShapes buckets, no per-length re-specialization | The recommended path. Apache-2.0. [confidence: high] |
| **FluidAudio `KokoroAneManager`** (Echo's OLD engine) | 7 fixed stages; default `ane-tail-gpu` (tail/iSTFT on GPU, ~5 stages on ANE) | Crashes on A14 long inputs | **No** — the palettized large-stride vocoder conv falls to BNNS and traps at runtime on long T_a | This is the configuration that wedged Echo. [confidence: high] |
| **MLX-Swift** (`mlalma/kokoro-ios`, `adriancmurray`, etc.) | Entire graph incl. vocoder on **GPU/Metal** — never touches ANE | A14 GPU *capable in principle*, but **gated iOS 18+** and **A14 unvalidated** | Yes (sidesteps ANE entirely) | ~3.3x RT on iPhone 13 Pro; OOMs at 30s on 4 GB iPhone 12 Pro. [confidence: high] |
| **sherpa-onnx** (single ONNX graph) | **CPU only** — CoreML EP fails on Kokoro's dynamic shapes (issue #1792) | Runs on A14 | Yes (no ANE) | Slow: tens of seconds; int8 *slower* than fp32 on iPhone (issue #2374). Not how competitors get instant start. [confidence: high] |
| **kokoro-onnx / ONNX ladder** | CPU via ONNX Runtime | Runs on A14 | Yes (no ANE) | fp32 326 MB → q8f16 86 MB. Functional but not the instant-start path. [confidence: high] |

**Cross-cutting conclusion:** A14 runs Kokoro via (a) fixed/static-shape CoreML with a deliberate ANE/CPU/GPU split, or (b) pure CPU/MLX-GPU. The *only* path that gives both small load **and** instant start on A14 is fixed-shape CoreML — which is what Echo just adopted, and the most plausible (unconfirmed) explanation for Fox Reader's behavior [confidence: med].

## 3. The libBNNS / ANE trap — confirmed root cause + confirmed mitigations

**Confirmed mechanism (Echo-specific):** Core ML partitions a model across ANE (private), GPU (MPS), and CPU (BNNS/Accelerate). When an op can't stay on the ANE it is dispatched to BNNS. On Echo's old `ane-tail-gpu` split, the palettized large-stride vocoder convolution was unsupported on the A14 ANE, fell to BNNS, and **trapped at runtime inside `BNNSGraphContextExecute_v2`** on the large dynamic tensor produced by long input (high acoustic-frame count T_a). Confirmed by xcsym + git in Echo's `CODE_AUDIT_NARRATION.md` [confidence: high].

**Important corrections to common misframings** (don't repeat these in the plan):
- It is **not** a compile-time `ANECCompile() FAILED`. The `mattmireles` README's `ANECCompile()` failure describes *its own unified full-ANE graph* being rejected on A14/A17 Pro — a *different* plan Echo never shipped [confidence: high].
- It is **not** proven to be the same failure as Apple Forums thread 821073 (an iOS-26.4 **model-load hang** during AOT recompilation). That thread proves uncatchable C++-origin libBNNS exceptions are *real*, but it's load-vs-inference, hang-vs-trap, OS-regression-vs-hardware — treat as a separate failure mode unless an A14 inference-time SIGTRAP stack is captured from Echo directly [confidence: high].
- The "palettized non-Float16 LUT disqualifies the op" sub-theory is **unverified and self-contradictory** (a disqualified op falls to CPU/GPU; Echo's trap was *inside* the ANE/BNNS path). int8-LUT palettization is an iOS18+/A17+/M4 feature that postdates A14. The **dynamic-shape** part of the explanation is the defensible part; the LUT-quantization part is not [confidence: med→low].

**Confirmed mitigations, in order of effectiveness** (the new engine implements 1–3):
1. **Fixed-shape / bucketed (EnumeratedShapes) decoder** so there is no per-length AOT re-specialization — this removes the throw site entirely. RangeDim only runs on ANE at the single default shape; any other shape → 0% ANE / full CPU fallback (coremltools #2370: 375 it/s @78% ANE vs 60 it/s @0%). EnumeratedShapes keeps ~71% ANE at *any* enumerated shape [confidence: high].
2. **Compute the hn-NSF harmonic source in Swift + Accelerate** (double-precision phase accumulation), off the ANE [confidence: high].
3. **Replace `nn.Linear` with `Conv1d(kernel_size=1)`** so the generator stays on a single ANE-eligible path (48→0 linear ops); independently mandated by Apple's ANE-transformers research [confidence: high].
4. Route with `MLComputeUnits.cpuAndGPU` to bypass the ANE compiler (a debugging baseline, not the perf path) [confidence: high].
5. Cap sequence length via chunking [confidence: high].

**Why asset-swap beats compute-unit changes:** `.cpuOnly` did **not** fix the libBNNS-AOT hang in the forum report because that trap is in the Espresso/BNNS *compile* stage, not the runtime compute unit. Eliminating per-length re-specialization (fixed buckets) is the reliable fix; only changing `computeUnits` is not [confidence: high].

## 4. Instant-start streaming

**Architecture (universal across every real streaming-TTS stack):** synthesize-the-first-sentence-then-stream. Split text on punctuation; synthesize **only the first short chunk**; start playback the instant it's ready; synthesize the rest ahead of the playhead via a producer-consumer queue. This is **not** a faster vocoder — it masks both total synthesis cost *and* cold start [confidence: high]. Note Kokoro is **non-autoregressive** (it renders a whole clip per call), so for Echo "streaming" means *scheduling chunk synthesis*, not true sub-chunk streaming — the levers are (a) first-chunk size and (b) play-ahead depth, not a streaming decoder [confidence: high].

**First chunk:** a single short sentence/clause (~5–15 words), **never split mid-sentence** (Azure: mid-sentence splits cause choppy pitch/expression). Kokoro accepts up to 510 phoneme tokens but long inputs cause rushed speech/artifacts; Kokoro-FastAPI defaults min 175 / max 250 tokens. A ~5–10 word clause is ~1–2 s of audio → maps to Echo's smallest (3s) bucket [confidence: high].

**Cold start is the biggest threat to <1s first word and must be paid before the user taps play.** The dominant first-launch cost is the one-time CoreML compile ("a few seconds"). **Pre-warm**: compile + load + one throwaway synthesis when the reader view opens, so visible time-to-first-audio is only first-chunk inference [confidence: high].

**Realistic first-chunk latency on A14:** GPU references (RTF ~0.03, 28 ms first-audio on RTX 5090, networked 300–800 ms) are *not* the on-device story. On-device Apple-silicon RTFx ranges ~12–79x (Macs) down to ~2–4.5x on iPhones (A17 ~4–4.5x; A14 the slowest). A 3s chunk is therefore **~1.2–1.5 s of warm compute on A14 — i.e. likely just over 1 s, not comfortably under** [confidence: med]. **Do not promise sub-1s from bucket choice alone**; pre-warm is what makes the *perceived* start fast.

**Playback primitive:** `AVAudioEngine` + `AVAudioPlayerNode` + `scheduleBuffer` (NOT `AVAudioPlayer`/render-then-play-a-file). Schedule PCM buffers; use each buffer's completion handler to schedule the next (self-clocking queue). Keep ~2 buffers in flight; `.interrupts` clears the whole queue (use only for seek/stop). A DEV.to pipeline measured ~180 ms TTFA, <5 ms inter-chunk gaps, 2–4 MB memory on iPhone 15 Pro [confidence: high]. **Format:** Kokoro emits 24 kHz mono PCM; the mixer wants 32-bit float at 44.1/48 kHz — convert each chunk with `AVAudioConverter` and accumulate to frame boundaries [confidence: high].

**Backpressure / watermark:** start playback after ~0.5 s buffered; **pause synthesizing once the queue exceeds ~3 s ahead** to cap CPU/ANE/thermal load. This is what makes long-form on-device reading sustainable [confidence: high].

**Thermal/battery trade vs render-then-play** [confidence: med]:
- Sustained on-device neural TTS **measurably heats the device and drains battery** on long sessions — independently documented for Apple silicon (ANE optimized for *burst*, throttles under continuous load; iPhone 14 Pro ~40% slowdown after consecutive AI ops; ~10–12 W / 90–95 °C under heavy CPU inference; +8.4 °C in continuous on-device speech workloads). Apple's ANE targets perf/watt <10 W (A12+), so keeping the heavy decoder **on the ANE** (vs CPU/GPU) helps both latency *and* power.
- Streaming spreads compute over playback and (with backpressure) self-throttles → lower peak load, lower perceived latency. Pre-render-and-cache pays the energy cost once and gives instant replay/seek but costs upfront wait + storage.
- **For Echo's study-on-route use case the right answer is a hybrid:** stream the first listen, then **persist the rendered audio to the existing `NarrationCache`** so resume/seek never re-synthesizes.

## 5. Fox Reader specifically — only what is genuinely sourceable

**Sourceable (from the App Store listing + the developer's GitHub-Pages privacy policy):**
- Full name "**Fox Reader: AI Audiobook Maker**", developer Salman Ahmad, Books category, **~409 MB**, converts EPUB/PDF/MOBI/TXT to audiobooks [confidence: high].
- Listing repeatedly claims **fully on-device / offline neural TTS** ("Neural voices… run on your device — not on a server"; "Nothing leaves your device") but **never names the model** — "Kokoro" appears nowhere in any web-public text [confidence: high].
- Default narrator voice is publicly named "**Heart**" (v1.2 notes). Kokoro's canonical default is `af_heart` ("Heart") — **circumstantial** evidence of Kokoro, not an acknowledgement [confidence: med].
- The privacy policy names **EPUBKit** (parsing) and **Apple's on-device LLM** (summaries) but is **conspicuously silent on the TTS engine** — the absence is itself a verifiable fact [confidence: high].
- Business model: free with optional ad-free subscription (7-day trial); current line ~v1.2; only ~3 public ratings [confidence: high].
- 409 MB total is *consistent with* a bundled Kokoro CoreML model + voice packs but does **not** prove it [confidence: low].

**The owner's firsthand observations** (not web-sourceable, but reliable): the in-app v1.3 voice picker states "All voices run fully on-device via Kokoro"; runs on his A14; "few-seconds download then near-instant playback."

**Cannot be determined (closed-source, no repo, no dev blog, App Store returns 429):**
- Which Kokoro **runtime/port** (fixed-shape CoreML vs MLX vs ONNX vs custom) — *this is exactly the question Echo most wants answered and it is genuinely unknowable from public materials.*
- The **compute-unit split / quantization / how it avoids the A14 BNNS trap.**
- Whether the model is **bundled vs downloaded** on first run, and any model/voice download sizes.
- Whether it **gates by chip** (it ran on the owner's A14, but no per-chip restriction is published).
- Whether the "few-seconds download" is a **~0.5 MB voice pack** (very plausible: voice embeddings are ~510 KB each, all ~52 voices ≈ 27 MB) atop a bundled/pre-cached model — **inference from file sizes, not confirmed** [confidence: med].

## 6. Implications for Echo

**Confidence the fixed-shape engine passes A14 verify: MEDIUM-HIGH.** The mechanism that caused the old crash (per-length re-specialization of a dynamic, palettized vocoder → BNNS trap) is *structurally removed* by the new engine (static fp16 buckets, harmonic source off-ANE, zero Linear ops), and that exact engine lists iPhone 12 Pro as a tested device. The reason it's not "high" is purely empirical: the wedge-free bench was **M1 Pro only**, and no public source measures this engine on A14. Verify before claiming success [confidence: med-high].

**What's already correct in Echo (do not "fix" what's done):**
- `NarrationModelStore.swift:31` already prunes to buckets **[3, 7, 10, 15]** and drops the 30s decoder / `f0ntrain_t1200` — so Echo **never uses the 30s bucket**.
- `NarrationService` already **caps each synthesize at ≤200 chars**, so Echo **already never feeds a full chapter as one tensor** and already selects the smallest fitting bucket.
- The fixed-shape engine does **NOT** OOM at 30s on iPhone 12 Pro (it completes in ~12.3 s; it's the *MLX* variant that OOMs). Don't describe the adopted engine as OOMing [confidence: high].

**What to watch for on A14:**
- **Cold-start compile** dominates first-launch; without pre-warm the first word is multi-seconds.
- **Per-chunk warm latency** ~2.4x realtime on A14 (≈12.3 s for 30s). A 3s chunk ≈ 1.2–1.5 s warm — fine for pre-buffered streaming, marginal for a literal <1s promise.
- **Thermal throttling on long sessions** — backpressure + caching are the defense.
- **CloudKit synth-anchor leak** (audit §6.2, Medium) is an existing open item, unrelated to A14 but in the narration area.

**How to shape the hybrid streaming item:**
- **Chunk size:** first chunk = first sentence/clause (~5–15 words, ≤ the 3s bucket); never split mid-sentence; subsequent chunks ≤200 chars (Echo's existing cap), each routed to the smallest fitting bucket.
- **Scheduler:** producer-consumer over `AVAudioEngine`/`AVAudioPlayerNode`; pre-warm on reader-view open (compile + load + 1-word throwaway); start playback at ~0.5 s buffered; **backpressure ceiling ~3 s ahead**; convert 24 kHz→48 kHz per chunk via `AVAudioConverter` at frame boundaries; `.interrupts` only on seek/stop.
- **Invariant (critical):** "streaming" produces ephemeral PCM for *immediate playback only*. A **chapter is marked `rendered` only once the full AAC file + word/anchor timings exist** in `NarrationCache` — a partially-streamed chapter must never be recorded as rendered, or resume/seek/karaoke will read incomplete state. Stream the first listen → persist the complete render → all future plays read cache (no re-synthesis, no repeat energy cost).

## 7. Open questions / what to test on-device

1. **The make-or-break gate:** run the new fixed-shape engine on a real **A14 (iPhone 12 Pro)** with a real book and **confirm no wedge** on long inputs — the M1 Pro bench does not cover this [confidence: high this is the gate].
2. **Capture an A14 stack trace** if it *does* still crash (xcsym): is it the same `BNNSGraphContextExecute_v2` runtime trap, or a new load-time AOT hang? This is the only way to settle whether thread-821073's failure mode also applies to Echo [confidence: high].
3. **Measure real time-to-first-audio on A14** for a 3s first chunk, cold vs pre-warmed — to know whether <1s is achievable or whether the honest promise is "near-instant via pre-warm" (~1–1.5 s) [confidence: med].
4. **Thermal/battery on a 30–60 min route session** with streaming + backpressure: does A14 throttle, and does the ~3 s play-ahead ceiling hold peak load down? [confidence: med].
5. **Confirm the shipped CoreML asset footprint** — verify Echo's vendored `swift/` pipeline is pruned to [3,7,10,15] on disk (not the full ~1 GB duplicated bucket set) so download/install stays reasonable [confidence: med].
6. **Does keeping the decoder on the ANE (vs cpuAndGPU) actually help power/heat on A14**, or does A14-specific behavior make `.cpuAndGPU` the safer-but-warmer fallback? Empirical only.

---
**Key file references (for the implementing engineer):** `EchoCore/Services/Narration/NarrationModelStore.swift:31` (bucket pruning), `EchoCore/Services/Narration/NarrationService.swift` (≤200-char chunk cap; pronunciation overrides applied at text layer), `CODE_AUDIT_NARRATION.md` (A14 BNNS-trap root cause + §6.2 CloudKit anchor leak), `docs/superpowers/plans/2026-06-18-lexicon-only-g2p-pronunciation-overrides.md` (current engine plan + remaining on-device verify gate).
