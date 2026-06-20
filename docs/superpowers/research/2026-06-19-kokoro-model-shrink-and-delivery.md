<!--
Migration brief produced 2026-06-19 by a 30-agent fan-out → adversarial-verify → synthesize
workflow (wf_bca5f8d9-4f8): 22 claims supported, 2 refuted, 0 unverifiable. Trigger: Echo
downloads a 731 MB Kokoro CoreML set from HuggingFace at runtime (vs Fox Reader's 409 MB whole app),
slowly and unreliably (Xet CDN timeouts on A14). Captured here because the workflow output file is
ephemeral. Confidence tags are the synthesis agent's. This is a sequenced plan, not yet executed.
-->

> [!WARNING]
> **SUPERSEDED (2026-06-19) by `2026-06-19-kokoro-onnx-pivot-decision.md`.** A subsequent on-device A14
> run showed the fixed-shape CoreML engine takes ~20 min of first-run AOT compile — unusable — so the
> decision is to pivot the engine to **ONNX Runtime (CPU)**, which collapses the model set to a single
> ~163 MB `model_fp16.onnx`. That **obsoletes this entire shrink/dedup/Background-Assets plan** (the
> 731 MB CoreML set goes away). Kept for reference only; do not execute the steps below.

# Migration Brief: Shrinking + Fast-Delivering Echo's Kokoro Model Set

## 1. Bottom line

**Yes — 731 MB can realistically reach ~330–360 MB (under Fox's 409 MB) while staying A14-safe, with no model re-export and no ANE risk at all.** [confidence: high]

The single highest-leverage move is **file-level weight dedup, not EnumeratedShapes.** The four shape buckets of `decoder_pre`, `har_post`, and `f0ntrain` each carry a **byte-identical `weight.bin`** — only the small per-shape `.mlmodel` spec differs. Verified on the HF blob API: `decoder_pre` weight.bin shares one LFS oid (`9932a592f367`, 67,190,976 B) across all 4 buckets; `har_post` one oid (`d184cac25716`); `f0ntrain` one oid (`5dd6617aba20`). [confidence: high] So ~381 MiB of what Echo downloads and stores today is pure duplication. Collapsing each family to one weight copy is **~269→67, ~159→40, ~82→21 MB** with **zero change to the compiled graph the ANE executes** — it touches only on-disk/on-wire bytes, not what runs. [confidence: high]

This matters because **EnumeratedShapes is the wrong first tool.** It solves the *shape* problem; it does not by itself dedup weights across what are currently separate `.mlpackages`, and the one family where it would matter (`decoder_pre`, the only ANE-routed stage) is precisely where it carries A14 ANE-residency risk. Dedup gets the **identical ~269→67 MB size win without any ANE/OS fragility.** [confidence: high]

Crucial reframe confirmed in the code: **only `decoder_pre` is ANE-routed** (`KokoroPipeline.swift:324`, `.cpuAndNeuralEngine`). `duration` (:297), `f0ntrain` (:312), and `har_post`/generator (:336) all run `.cpuAndGPU`. That is **462 of 731 MB (~63%) with no ANE benefit to lose** and no A14 BNNS-trap exposure. The A14 worry binds exactly one family. [confidence: high]

## 2. Shrink — EnumeratedShapes

A single `.mlpackage` with EnumeratedShapes does carry **one** weight set, not N, and (unlike RangeDim) keeps a model on the ANE at any enumerated shape (coremltools #2370: ~71% ANE vs RangeDim's 0% off-default). [confidence: high] **But the realistic size win is identical to dedup, and the risk is higher** — the weights are already byte-identical, so EnumeratedShapes buys nothing dedup doesn't while adding re-export risk.

Per-family verdict:
- **f0ntrain** — cleanest candidate, but already `.cpuAndGPU` and dedup-able → no reason to re-export. [high]
- **decoder_pre / har_post** — coupled multi-input (the case upstream explicitly rejected; iOS 18+ allows index-matched multi-enumerated inputs, but **no public evidence it stays on the A14 ANE**, plus a macOS 15.5 regression + 3–4× non-default slowdowns reported). decoder_pre is the one ANE stage — the riskiest place to touch. [medium]
- **duration** — highest risk, lowest value (MaskedBidirectionalLSTM, coupled inputs, weights NOT identical across buckets, already `.cpuAndGPU`). Leave per-bucket. [high]

**Recommendation: do not re-export.** Dedup gets the same bytes risk-free. **Refutation honored:** "pre-warm each enumerated shape to neutralize the cost" is wrong — reports describe *persistent* per-prediction ANE→GPU/CPU fallback, not one-time warm cost; pre-warm (Echo has `warmPipeline`) won't rescue a fallback. [high]

## 3. Shrink — other levers

- **Drop the duplicate legacy duration package — safe.** `kokoro_duration.mlpackage` is byte-for-byte identical to `kokoro_duration_t128` (same git+LFS oid, 38,918,912 B); code already maps legacy→t128. Saves ~44.5 MB, zero ANE risk, once t128 is guaranteed present (grep for the literal cacheKey first). [high]
- **On-download dedup (free).** `downloadInternalFile` fetches each bucket's identical weight.bin separately (~381 MiB redundant). Keep an LFS-oid→localpath map; on a repeat oid, hardlink/clonefile instead of re-downloading. Cuts wire payload ~731→~350 MB. [high]
- **Quantization — A14-SAFE vs A14-BREAKING:**
  - **int8 LINEAR (weight-only): A14-SAFE** — halves weight size; on A14 decompresses to fp16 at load (size-only win). Apply to the 3 **non-ANE** families only. [medium]
  - **Palettization (LUT): the single highest A14-BREAKING risk** — the exact wedge Echo escaped was a palettized large-stride conv trapping in libBNNS. **Never palettize decoder_pre.** Acceptable only on the `.cpuAndGPU` stages, and even there on-device-prove no trap. [high]
- **Hard A14 constraint:** `decoder_pre` stays **fp16, fixed-shape, on the ANE**, untouched beyond dedup.
- **Realistic floors:** Tier 1 (fp16 + dedup + drop legacy) ≈ **~285–305 MiB** (safe target, already under Fox). Tier 2 (int8/palettize the 3 non-ANE families) ≈ ~180–260 MiB (must be on-device verified). [medium]

## 4. Delivery — ODR vs Background Assets vs keep-HF

**Recommendation: Background Assets, not ODR.** [confidence: high]

**ODR is the wrong bet** even though it fits sizewise: (1) **deprecated** — Apple deprecated ODR + `NSBundleResourceRequest` (WWDC25 session 325; DTS: "wouldn't be wise to use ODR in a new product"). (2) **Structural mismatch** — ODR is *purgeable* (iOS evicts unused tags under disk pressure and silently re-downloads; `setPreservationPriority` only biases LRU). Echo's set today lives in Application Support behind a `.complete` sentinel — excluded from backup but **not** system-purgeable. ODR would strictly worsen that. [high]

**Background Assets — the "installed-app feel."** Essential assets download **during install** (folded into the App Store progress bar), on Apple's CDN, with system retry/resume/compression. Apple-Hosted tier requires **iOS 26** (Echo's floor qualifies); **self-hosted** Background Assets (iOS 16+, own CDN via `BAManifestURL`) is the fallback if iOS 18 must be served. [high]

**Gotchas:**
- **Oversized Essential payloads get App Review REJECTED** (install visibly stalls; a dev with ~8 GB was rejected twice). A shrunk ~300 MB set is far safer; consider **non-essential** Background Assets (download after first launch, gate the narration UI on completion) to avoid the install-blocking failure mode. **This is the reason to shrink first, then deliver.** [medium]
- Ship the `.mlpackage` as a folder reference (it's a directory); prefer shipping **pre-compiled `.mlmodelc`** to avoid the multi-minute on-device compile; compiled output belongs in a dir you control, never inside a purgeable asset dir. [high]
- **WhisperKit (already in Echo) defaults to runtime HF download** (`WhisperSession.swift:34`, bare `WhisperKit(model:)`) — i.e. the same pattern being escaped; it *optionally* supports `download:false`+`modelFolder`. Cite as proof bundling is possible, not as already-demonstrated. The old `MLModelCollection` deploy API is dead ("Use Background Assets or NSURLSession instead"). [high]

## 5. Sequenced plan

- **Step 0 — Drop legacy duration package.** Pure app code. ~44.5 MB. Trivial risk (grep cacheKey first). [high]
- **Step 1 — On-download + on-disk weight dedup.** Pure app code in `NarrationModelStore` (LFS-oid map + hardlink/clonefile siblings). Cuts wire ~731→~350 MB and disk to ~285–305 MiB. Low risk (ANE executes the identical graph). Owner-gate: on-device sanity that hardlinked packages compile/load on A14. **Highest leverage, no spike.** [high]
- **Step 2 — Delivery → Background Assets.** Pure app code + asset-pack upload. Apple-Hosted Essential (iOS 26) or self-hosted (iOS 18). Bump `modelSubdir` v5→v6 so the collapsed set ships without colliding with installed v5. Medium risk (App Review essential-size — mitigated by Steps 0–1). Owner-gate: Essential vs non-essential; verify install flow on device. No spike. [high]
- **Step 3 (optional) — int8/palettize the 3 non-ANE families.** coremltools spike. ~180–260 MiB. Medium risk (audio quality; f0ntrain/tail fp16-sensitive). **Never decoder_pre.** Owner-gate: A14 A/B listen + confirm `.cpuAndGPU` holds. [medium]
- **Step 4 (do NOT pursue unless packaging demands) — EnumeratedShapes/multifunction re-export of decoder_pre+har_post.** coremltools spike + GitHub PyTorch source. Same size as dedup already achieved, adds A14 ANE-residency risk to the one ANE stage. Mandatory owner-gate: on-device A14 Instruments profile (ANE residency at every shape, no BNNS trap). [medium]

**Order rationale:** Steps 0–2 get Echo under Fox's footprint *and* installed-app-fast with **zero ANE risk and zero coremltools work.** Steps 3–4 are diminishing-return, risk-adding, device-gated — separate spikes, not blockers.

## 6. What to verify on-device / open questions

1. **(Blocking, pre-Step-2 ship)** A14 + M1 Pro: dedup'd/hardlinked set compiles + synthesizes with no BNNS wedge and no audio change. Inherits the already-open A14 verification gate on the fixed-shape engine.
2. **Background Assets install flow** on a real device + TestFlight: Essential download folds into install without stalling; compiled `.mlmodelc` lands in a non-purgeable dir.
3. **(If Step 3)** A14 A/B listening test for int8/palettized non-ANE stages; confirm `.cpuAndGPU` routing isn't silently re-placing ops on the ANE.
4. **(If Step 4 only)** A14/A15 Instruments Core ML profile: does index-matched multi-input EnumeratedShapes decoder_pre stay 100% on the ANE? **No public evidence either way — the single biggest technical risk.**
5. **Duration bucket weights** — re-confirm t32/t64/t128/t256 are genuinely non-identical before assuming they can't dedup (HF oids differ; spot-check on disk).
6. **Fox's actual delivery** remains **unknowable** (closed-source); "compact model on first use" is consistent with an ~86–170 MB quantized Kokoro but is inference. Don't over-anchor the ~400 MB target on it.

**A14-wedge re-introduction summary:** The *only* changes that can re-trigger the BNNS ANE trap touch **decoder_pre on the ANE** — palettizing it (Step 3 excludes it) or EnumeratedShapes/re-export of it (Step 4, device-gated). Steps 0–2 and quantizing the three `.cpuAndGPU` families **cannot** reach the trap by construction. [confidence: high]

**Doc-sync (when implemented):** update `ARCHITECTURE.md` (Background Assets delivery + dedup), `CODE_AUDIT_NARRATION.md`, and the `2026-06-18-lexicon-only-g2p` plan's renderVersion note (v5→v6).
