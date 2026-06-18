# Fixed-Shape Kokoro Narration Engine Swap (iOS + macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Echo's FluidAudio-backed `KokoroTTSEngine` — whose dynamic-shape Kokoro vocoder wedges the Apple Neural Engine mid-book on both A14 iPhone and M1-Pro Mac — with a `KokoroFixedShapeEngine` built on the vendored, fixed-shape-bucketed `mattmireles/kokoro-coreml` Swift `KokoroPipeline`, which a Python reference run proved wedge-free (198 in-process synth calls, flat 0.074× RTF) on the same M1 Pro.

**Architecture:** Vendor the self-contained `swift/Sources/KokoroPipeline` SwiftPM package (CoreML + Accelerate, no external ML deps). Behind Echo's existing `TTSEngine` actor seam, add `KokoroFixedShapeEngine` that does text → MisakiSwift G2P → 178-token phoneme IDs → `[N,256]` `af_heart` refS row → `KokoroPipeline.synthesize(...)` → `TTSChunk` (mono Float32 24 kHz). Bucketed CoreML models are downloaded (pruned set) on first use to Application Support and compiled to cached `.mlmodelc`. The hn-NSF harmonic source runs in Swift/Accelerate (not the ANE), and the wedge-prone decoder runs as fixed-shape CoreML — the exact architecture the Python proof validated.

**Tech Stack:** Swift 6 / SwiftUI, CoreML, Accelerate, MisakiSwift (Apache-2.0 G2P), GRDB (unchanged), AVFoundation (unchanged ALAC stream-to-disk).

## Global Constraints

- **16 GB machine:** NEVER run two `xcodebuild` invocations concurrently, NEVER enable parallel testing, NEVER uncapped `-jobs`. Use `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` for edit→test loops; full run is `make test`. (CLAUDE.md)
- **License (GPL-3.0 app):** Kokoro model = Apache-2.0; MisakiSwift = Apache-2.0. **espeak-ng (GPL) is NOT in the graph (confirmed P0.3) ✅.** MisakiSwift DOES pull MLX (`mlx-swift 0.30.2` + `MLXNN` + `MLXUtilsLibrary` + swift-numerics + ZIPFoundation) + ~18 MB resources — accepted for v1 (see Phase 3 decision). All Apache/MIT/permissive — no GPL contamination.
- **Platform floor:** MisakiSwift requires iOS 18 / macOS 15. Echo already targets exactly `IPHONEOS_DEPLOYMENT_TARGET = 18.0` / `MACOSX_DEPLOYMENT_TARGET = 15.0` — no floor change needed. (KokoroPipeline itself is iOS 16 / macOS 13.)
- **Conventional Commits** for every commit. (CLAUDE.md)
- **SPDX header `// SPDX-License-Identifier: GPL-3.0-or-later` MUST remain line 1** of every Echo `.swift` file. A PostToolUse SwiftFormat hook reflows the whole file on edit and can displace the header below an import — verify SPDX is line 1 after each edit. (memory: echo-swiftformat-edit-hook)
- **Audio invariant:** `TTSChunk` is mono **Float32 PCM at 24_000 Hz**. `SynthesisResult.audio` already satisfies this; never resample.
- **Voice scope:** Ava (`af_heart`) only for this swap. Do not add other voices.
- **Reversibility:** Keep `KokoroTTSEngine.swift` and the FluidAudio dependency in-tree until BOTH macOS and the A14 iPhone are verified. Reverting the swap must stay a one-line change in `NarrationEngineFactory.make()`.
- **renderVersion:** Bump `NarrationFileNaming.renderVersion` `4 → 5` (different model + DSP + G2P = different bytes; old cache must invalidate and regenerate once).
- **Doc-sync (CRITICAL):** On completion update `ARCHITECTURE.md`, `CODE_AUDIT_NARRATION.md`, `CHANGELOG.md`, and the `narration-feature` memory entry. (CLAUDE.md doc-sync skill)

---

## File Structure

**Vendored (copied verbatim, not authored):**
- `ThirdParty/KokoroPipeline/` — the entire `/tmp/km_probe/gh/swift/` package (Package.swift + Sources/KokoroPipeline + Tests). Added as a local SwiftPM package dependency of the iOS + macOS app targets.

**New Echo files (`EchoCore/Services/Narration/`):**
- `KokoroFixedShapeEngine.swift` — the new `TTSEngine` actor (G2P → IDs → refS → KokoroPipeline → TTSChunk).
- `KokoroPhonemeVocab.swift` — loads bundled `_kokoro_vocab.json` ([String:Int32]); maps a phoneme string to `[Int32]` IDs with BOS/EOS.
- `KokoroVoicePack.swift` — loads the bundled `af_heart` `[N,256]` Float32 matrix; selects the refS row by clamped phoneme length.
- `KokoroG2P.swift` — thin wrapper over MisakiSwift `EnglishG2P(british:false)` returning a phoneme string.
- `NarrationModelStore.swift` — downloads the pruned bucket set from Hugging Face to Application Support on first use, returns the `modelsDirectory` URL, owns the hn-NSF weight constants.

**New Echo resources (bundled into EchoCore / app resources):**
- `_kokoro_vocab.json` (copied from `/tmp/km_probe/gh/_kokoro_vocab.json`)
- `af_heart.f32` — the `[N,256]` Float32 voice matrix (converted from the Hub `.pt`/`.bin` once, bundled as a flat little-endian Float32 blob + a sidecar row count).

**Modified Echo files:**
- `EchoCore/Services/Narration/NarrationEngineFactory.swift:15` — `make()` returns `KokoroFixedShapeEngine()`.
- `EchoCore/Services/Narration/NarrationFileNaming.swift:17` — `renderVersion = 5`.
- `EchoCore/Services/Narration/NarrationCapability.swift` — relax the iPhone gate after A14 verification (Task 5.2).
- `EchoCore/Services/Narration/NarrationService.swift:227` — DEBUG smoke test constructs `KokoroFixedShapeEngine()` (kept consistent with the factory).
- Project files (`Echo.xcodeproj`) — link the local KokoroPipeline + MisakiSwift packages to the iOS + macOS targets; add the two resources.

**New tests (`EchoTests/`):**
- `KokoroPhonemeVocabTests.swift`, `KokoroVoicePackTests.swift`, `KokoroFixedShapeEngineTests.swift`, `NarrationCapabilityTests.swift` (extend existing if present).

---

## Phase 0 — De-risk spike — ✅ COMPLETE (2026-06-18, M1 Pro)

> **RESULT: PASS on all three gates — proceed to Phase 1.** Verbatim outcomes:
> - **0.1 Vocab parity — PASS.** Diffing every character in MisakiSwift's full `us_gold.json` + `us_silver.json` lexicons against the 114-symbol Kokoro vocab (`_kokoro_vocab.json`, ids 1–177) found **0 characters outside the vocab**. (Parity holds by construction — hexgrad built the Kokoro vocab from Misaki's phoneme inventory.) The end-to-end *Swift* MisakiSwift run was blocked by an MLX-metallib CLI packaging quirk (works in app bundles; not a parity issue), so the lexicon-charset analysis is the authoritative check; it is in fact broader (whole dictionary vs a sample corpus). Residual: the `unk: "❓"` OOV marker is not in the vocab → a truly-unphonemizable token drops (rare; acceptable).
> - **0.2 On-device-Swift no-wedge — PASS.** `kokoro-bench --batch` ran **123 in-process synth passes interleaved across all four bucket shapes (3s/7s/15s/30s)**, exit 0, every output `"status":"ok"`, `swift_error: 0`, no wedge — under constant model evict/reload churn (harder than real usage). Per-synth `wall_time_s ≈ 0.50` (~0.07× RTF). 4 Swift-generated WAVs validated (24 kHz, durations matching buckets) and delivered to the owner's Desktop.
> - **0.3 MisakiSwift deps/license — Apache-2.0, NO espeak ✅, BUT requires MLX.** Pulls `mlx-swift 0.30.2` + `MLXNN` + `MLXUtilsLibrary 0.0.6` (+ swift-numerics, ZIPFoundation) and ~18 MB resources (us/gb BART safetensors + gold/silver lexicons). Floor **iOS 18 / macOS 15 = exact match to Echo's targets** ✅. The G2P core uses MLX for the BART OOV fallback, so it cannot be lifted MLX-free without a fork → see the Phase 3 decision.
>
> The original task steps below are retained as the executed record.

### Task 0.1: Vocab parity — MisakiSwift output ⊆ the 178-token vocab

**Why:** The single genuine correctness risk. If MisakiSwift emits any IPA character not in `_kokoro_vocab.json`, that phoneme silently drops (`filter(notNil)`), producing subtly-wrong pronunciation. We must prove every emitted character maps.

**Files:**
- Create: `/tmp/km_probe/gh/swift/Sources/VocabDiff/main.swift` (throwaway executable target)
- Reference: `/tmp/km_probe/gh/_kokoro_vocab.json` (178 entries), `/tmp/km_probe/gh/ios-bench/Vendor/kokoro-ios/.../MisakiG2PProcessor.swift`

- [ ] **Step 1: Add a throwaway executable target** to `/tmp/km_probe/gh/swift/Package.swift` that depends on MisakiSwift (point it at the same `github.com/mlalma/MisakiSwift` version `1.0.3` used by the vendor's `kokoro-ios/Package.swift`).

- [ ] **Step 2: Write the diff driver.** Run `EnglishG2P(british:false).phonemize(text:)` over a large English corpus (concatenate the two demo texts at `/tmp/km_probe/gh/demo/*.md` plus the Echo "git-happens" sample if available), collect the set of unique scalar characters across all returned phoneme strings, load `_kokoro_vocab.json` keys, and print `emitted \ vocab` (chars emitted but NOT in vocab) and `vocab \ emitted` (unused vocab entries).

```swift
// /tmp/km_probe/gh/swift/Sources/VocabDiff/main.swift
import Foundation
import MisakiSwift

let vocabURL = URL(fileURLWithPath: "/tmp/km_probe/gh/_kokoro_vocab.json")
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL)) as! [String: Any]
let vocab = root["vocab"] as! [String: Int]
let vocabChars = Set(vocab.keys.flatMap { Array($0) })   // keys are single chars

let g2p = EnglishG2P(british: false)
var emitted = Set<Character>()
for path in ["/tmp/km_probe/gh/demo/frankenstein5k.md", "/tmp/km_probe/gh/demo/gatsby5k.md"] {
    let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    let (phonemes, _) = g2p.phonemize(text: text)
    emitted.formUnion(phonemes)
}
let missing = emitted.subtracting(vocabChars).subtracting([" "])
print("EMITTED-NOT-IN-VOCAB (\(missing.count)):", missing.sorted())
print("UNUSED-VOCAB (\(vocabChars.subtracting(emitted).count)):", vocabChars.subtracting(emitted).sorted())
```

- [ ] **Step 3: Run it.**

Run: `cd /tmp/km_probe/gh/swift && swift run VocabDiff`
Expected: **`EMITTED-NOT-IN-VOCAB (0): []`**. Any non-empty set is a parity failure — record exactly which characters, because they dictate whether a remap/normalization layer is needed in Task 3.1 (escalates Phase 3 to L).

- [ ] **Step 4: Record the verdict** in the plan's execution notes (pass = proceed; fail = list missing chars, STOP, reconsider).

### Task 0.2: On-device-Swift no-wedge datapoint via `kokoro-bench`

**Why:** The 198-call proof was the *Python* pipeline. This is the first *Swift* `KokoroPipeline` run on real hardware, and it confirms the package loads the same assets and produces audio without wedging.

**Files:** uses the existing `kokoro-bench` target + `/tmp/km_probe/gh/coreml/` models + `/tmp/km_probe/gh/hnsf_weights.json` + `/tmp/km_probe/gh/ios-bench/Resources/bench_inputs/*.json`.

- [ ] **Step 1: Build the benchmark.** Run: `cd /tmp/km_probe/gh/swift && swift build -c release`
Expected: builds `kokoro-bench` with no errors.

- [ ] **Step 2: Single-shot smoke + WAV.** Run:
```bash
cd /tmp/km_probe/gh/swift
.build/release/kokoro-bench \
  --models-dir /tmp/km_probe/gh/coreml \
  --inputs-dir /tmp/km_probe/gh/ios-bench/Resources/bench_inputs \
  --hnsf-weights /tmp/km_probe/gh/hnsf_weights.json \
  --input-key 7s --warmup 1 --iterations 1 \
  --wav /tmp/km_probe/swift_bench_7s.wav --output /tmp/km_probe/swift_bench_7s.json
```
Expected: exits 0, writes a non-silent WAV. Listen to confirm intelligible Ava.

- [ ] **Step 3: Loop all buckets many times for the wedge test.** Run each `--input-key` in `{3s,7s,10s,15s,30s}` with `--iterations 40` (≈200 passes total) in a single shell loop; watch for a hang or a CoreML error mid-run.
Expected: all complete; per-iteration time stays flat (no climb). Record avg RTF per bucket.

- [ ] **Step 4: Record the verdict** (pass = Swift package behaves like the Python proof; fail = capture the error + bucket, STOP).

### Task 0.3: MisakiSwift dependency-graph + license audit

**Why:** Confirms we can ship G2P without pulling MLX bloat or GPL espeak-ng into Echo.

- [ ] **Step 1:** Open `github.com/mlalma/MisakiSwift`'s `Package.swift` (the version pinned at `1.0.3`). Record its `dependencies` and its LICENSE.
- [ ] **Step 2:** Determine whether `MisakiSwift` (the G2P library itself, not the vendor's wrapper) transitively requires `mlx-swift`, `MLXUtilsLibrary`, or `eSpeakNG`. The vendor's `MisakiG2PProcessor` imports `MLXUtilsLibrary` only for the `MToken` type — confirm whether `MToken` is needed for our path (we only need the phoneme *string*, not tokens, for IDs).
- [ ] **Step 3: Record the verdict:** (a) MisakiSwift is Apache-2.0 with no espeak-ng → license clear; (b) if it pulls MLX, decide: accept MLX as a G2P-only dep, OR fork MisakiSwift to drop MLX, OR call only the MLX-free `phonemize` path. Document the chosen route — it sets the MisakiSwift integration shape for Task 3.2.

**Phase 0 gate: ✅ PASSED (2026-06-18) — proceed to Phase 1.**

---

## Phase 1 — Vendor the KokoroPipeline package

### Task 1: Vendor + link KokoroPipeline into the iOS + macOS targets

**Files:**
- Create: `ThirdParty/KokoroPipeline/` (copy of `/tmp/km_probe/gh/swift/`)
- Modify: `Echo.xcodeproj/project.pbxproj` (add local package + link to `Echo` (iOS) and `Echo macOS` targets)

**Interfaces:**
- Produces: `import KokoroPipeline` available in the iOS + macOS app modules; the public symbols `KokoroPipeline`, `SynthesisResult`, `KokoroVocabulary`, `HarmonicConstants`.

- [ ] **Step 1: Copy the package.** Run: `cp -R /tmp/km_probe/gh/swift /Users/dfakkeldy/Developer/Echo/ThirdParty/KokoroPipeline` then remove the executable/benchmark targets from its `Package.swift` (keep only the `KokoroPipeline` library + its tests) so Echo doesn't build the CLIs.

- [ ] **Step 2: Confirm the LICENSE** of the upstream package is Apache-2.0 and copy it to `ThirdParty/KokoroPipeline/LICENSE`. Add a one-line attribution to Echo's `ACKNOWLEDGEMENTS`/`README` third-party section.

- [ ] **Step 3: Add as a local SwiftPM package** in `Echo.xcodeproj` and link the `KokoroPipeline` product to BOTH the `Echo` (iOS) and `Echo macOS` app targets. (Mirror how FluidAudio/WhisperKit are linked.)

- [ ] **Step 4: Smoke-build both targets** (sequentially — never concurrent).
Run: `xcodebuild -scheme Echo -destination 'generic/platform=iOS' build` then the macOS scheme build.
Expected: both compile with `import KokoroPipeline` resolving. No code uses it yet.

- [ ] **Step 5: Commit.**
```bash
git add ThirdParty/KokoroPipeline Echo.xcodeproj README.md
git commit -m "build(narration): vendor fixed-shape KokoroPipeline SwiftPM package (iOS+macOS)"
```

---

## Phase 2 — Pruned runtime model download

### Task 2: NarrationModelStore — download + compile the pruned bucket set

**Decision (owner):** runtime download, pruned. Keep decoder_pre / decoder_har_post buckets `{3,7,10,15}`s, f0ntrain `{t120,t280,t400,t600}`, and ALL duration buckets (they are small). Drop the 30 s decoder + `f0ntrain_t1200` (largest, and unreachable once chunks are capped ≤15 s of audio). Enforce the cap so no chunk ever needs the dropped buckets.

**Files:**
- Create: `EchoCore/Services/Narration/NarrationModelStore.swift`
- Reference: `NarrationCache` (existing shared cache dir helper), `/tmp/km_probe/gh/scripts/download_models.py` (the HF file list + `mattmireles/kokoro-coreml` repo id)
- Test: `EchoTests/NarrationModelStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  actor NarrationModelStore {
      static let shared = NarrationModelStore()
      static let keptBucketSeconds: [Int] = [3, 7, 10, 15]
      static let hnsfLinearWeights: [Float] = [
          -0.08154187, -0.18519667, -0.18263398, -0.17837206, -0.09873895,
           0.08264039,  0.08743999, -0.39068547, -0.54774433]
      static let hnsfLinearBias: Float = -0.02945026
      /// Downloads (once) the pruned `.mlpackage` set into Application Support and
      /// returns the directory KokoroPipeline should load from. Idempotent.
      func ensureModels(progress: (@Sendable (Double) -> Void)?) async throws -> URL
  }
  ```
- Consumed by: `KokoroFixedShapeEngine.prepare()` (Task 4).

- [ ] **Step 1: Write the failing test** — a kept-bucket allow-list filter is correct (pure logic, no network).

```swift
// EchoTests/NarrationModelStoreTests.swift
import Testing
@testable import EchoCore

@Test func keptBucketsExcludeThirtySecond() {
    #expect(NarrationModelStore.keptBucketSeconds == [3, 7, 10, 15])
    #expect(!NarrationModelStore.keptBucketSeconds.contains(30))
    // hn-NSF constants match hnsf_weights.json exactly (9 weights + bias)
    #expect(NarrationModelStore.hnsfLinearWeights.count == 9)
    #expect(NarrationModelStore.hnsfLinearBias == -0.02945026)
}

@Test func downloadFileListPrunesLargeBuckets() {
    let files = NarrationModelStore.requiredModelFiles()
    #expect(files.contains("kokoro_decoder_har_post_15s.mlpackage"))
    #expect(!files.contains("kokoro_decoder_har_post_30s.mlpackage"))
    #expect(!files.contains("kokoro_f0ntrain_t1200.mlpackage"))
    #expect(files.contains("kokoro_f0ntrain_t600.mlpackage"))
}
```

- [ ] **Step 2: Run it — verify it fails** (`NarrationModelStore` undefined).
Run: `make build-tests && make test-only FILTER=EchoTests/NarrationModelStoreTests`
Expected: FAIL (no such type).

- [ ] **Step 3: Implement `NarrationModelStore`.** `requiredModelFiles()` returns the pruned file list (decoder_pre/har_post for kept buckets, the matching f0ntrain `t{120,280,400,600}`, all `kokoro_duration*` packages). `ensureModels` downloads each missing file from `https://huggingface.co/mattmireles/kokoro-coreml/resolve/main/coreml/<file>` into `NarrationCache`-rooted `Models/kokoro-fixed-v5/`, with a `.complete` sentinel written only after all files verify, retry-once per file (mirrors the macOS download timeout handling already noted in memory), and reports `progress`.

- [ ] **Step 4: Run the tests — verify they pass.**
Run: `make test-only FILTER=EchoTests/NarrationModelStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/NarrationModelStore.swift EchoTests/NarrationModelStoreTests.swift
git commit -m "feat(narration): pruned runtime model store for fixed-shape Kokoro"
```

---

## Phase 3 — G2P + vocab + refS Swift glue

### Task 3.1: KokoroPhonemeVocab — phoneme string → `[Int32]` IDs

**Files:**
- Create: `EchoCore/Services/Narration/KokoroPhonemeVocab.swift`
- Resource: copy `/tmp/km_probe/gh/_kokoro_vocab.json` → `EchoCore/Resources/_kokoro_vocab.json` (bundled)
- Test: `EchoTests/KokoroPhonemeVocabTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct KokoroPhonemeVocab {
      init() throws                                  // loads bundled _kokoro_vocab.json
      func ids(forPhonemes phonemes: String) -> [Int32]   // BOS + mapped(non-nil) + EOS
      var tokenCount: Int { get }                    // == 178
  }
  ```
- Consumed by: `KokoroFixedShapeEngine`.

- [ ] **Step 1: Write the failing test** (mirrors the Python `[0, *map(vocab.get), 0]` with nil-filtering).

```swift
// EchoTests/KokoroPhonemeVocabTests.swift
import Testing
@testable import EchoCore

@Test func mapsKnownPhonemesWithBosEosAndDropsUnknown() throws {
    let v = try KokoroPhonemeVocab()
    #expect(v.tokenCount == 178)
    // " " is id 16; "." is id 4; an unmapped char is dropped, not crashed.
    let ids = v.ids(forPhonemes: " .\u{0000}")   // space, period, NUL(unmapped)
    #expect(ids.first == 0 && ids.last == 0)      // BOS/EOS wrap
    #expect(ids == [0, 16, 4, 0])                 // NUL dropped
}
```

- [ ] **Step 2: Run — verify it fails.**
Run: `make build-tests && make test-only FILTER=EchoTests/KokoroPhonemeVocabTests`
Expected: FAIL.

- [ ] **Step 3: Implement.** Load the JSON `{"vocab": {char: id}}` into `[Character: Int32]`; `ids(forPhonemes:)` returns `[0] + phonemes.compactMap { map[$0] } + [0]`. If Task 0.1 found missing chars, add the documented normalization here (else none).

- [ ] **Step 4: Run — verify it passes.** Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/KokoroPhonemeVocab.swift EchoCore/Resources/_kokoro_vocab.json EchoTests/KokoroPhonemeVocabTests.swift
git commit -m "feat(narration): 178-token phoneme→id vocab loader"
```

### Task 3.2: KokoroG2P — MisakiSwift phonemizer wrapper

**DECISION (from P0.3): v1 ACCEPTS MLX as a G2P-only dependency.** MisakiSwift requires `mlx-swift` (the BART OOV fallback runs on MLX); there is no MLX-free path without forking. Rationale: MisakiSwift is the proven-quality Misaki G2P, vocab-parity is confirmed (P0.1), its platform floor matches Echo's exactly, and MLX is a first-party-quality Apple-ecosystem dependency. The binary cost (MLX runtime + Metal lib + ~18 MB resources) is acceptable next to the ~500 MB runtime model download. **Fast-follow (post-v1, optional):** a lexicon-only G2P (load MisakiSwift's gold/silver JSON + a Swift letter-to-sound OOV fallback, no MLX) to drop the MLX dependency if install size becomes a concern — deferred because it risks OOV pronunciation quality and is real work. **✅ DONE (2026-06-18) — see `docs/superpowers/plans/2026-06-18-lexicon-only-g2p-pronunciation-overrides.md`:** MLX was dropped and G2P is now lexicon-only; the OOV-quality risk is addressed not by a letter-to-sound fallback but by a user **pronunciation-override dictionary** (OOV words emit `unk`/silence unless the user supplies IPA). This also unblocked the iPhone-simulator test suite (mlx-swift#341).

**Files:**
- Create: `EchoCore/Services/Narration/KokoroG2P.swift`
- Modify: `Echo.xcodeproj` (add MisakiSwift `1.0.3` SwiftPM dep → transitively pulls `mlx-swift 0.30.2`, `MLXNN`, `MLXUtilsLibrary`, swift-numerics, ZIPFoundation; bundle its `us_*` resources). **Drop the `gb_*` resources (~6 MB) — Echo is US English only.**
- Test: `EchoTests/KokoroG2PTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct KokoroG2P {
      init()                                  // EnglishG2P(british: false)
      func phonemes(for text: String) -> String   // IPA phoneme string (spaces preserved)
  }
  ```

- [ ] **Step 1: Add MisakiSwift** (`https://github.com/mlalma/MisakiSwift` exact `1.0.3`) as a SwiftPM dep on the iOS + macOS targets. Confirm the MLX **metallib bundles correctly in the app** (the P0 bare-CLI `Failed to load the default metallib` error does NOT occur in a real app target, where `Bundle.module` resources are packaged — verify with a one-line on-device/sim `EnglishG2P(...).phonemize("test")` call early). Exclude the `gb_*` resources to save ~6 MB.

- [ ] **Step 2: Write the test** — non-empty phonemes for plain English, deterministic.

```swift
// EchoTests/KokoroG2PTests.swift
import Testing
@testable import EchoCore

@Test func producesNonEmptyPhonemesForEnglish() {
    let p = KokoroG2P().phonemes(for: "Hello world.")
    #expect(!p.isEmpty)
    #expect(p.contains(" "))   // word boundary preserved
}
```

- [ ] **Step 3: Implement** the wrapper calling `EnglishG2P(british:false).phonemize(text:).0`.

- [ ] **Step 4: Run — verify it passes.**
Run: `make test-only FILTER=EchoTests/KokoroG2PTests`
Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/KokoroG2P.swift Echo.xcodeproj EchoTests/KokoroG2PTests.swift
git commit -m "feat(narration): MisakiSwift G2P wrapper (Apache, no espeak)"
```

### Task 3.3: KokoroVoicePack — `af_heart` `[N,256]` refS selection

**Files:**
- Create: `EchoCore/Services/Narration/KokoroVoicePack.swift`
- Resource: `EchoCore/Resources/af_heart.f32` (+ `af_heart.rows` count) — produced once by converting the Hub `af_heart` voice tensor to a flat little-endian Float32 blob (see Step 0).
- Test: `EchoTests/KokoroVoicePackTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct KokoroVoicePack {
      init(named name: String) throws            // loads <name>.f32 ([rows*256] floats)
      func refS(forPhonemeCount n: Int) -> [Float]   // row clamp(n-1, 0, rows-1), 256 floats
  }
  ```

- [ ] **Step 0 (one-time asset conversion):** In Python at `/tmp/km_probe/gh`, load the `af_heart` voice pack the SAME way the validated pipeline did (`load_single_voice('af_heart')` → `[N,256]` float32), and write it as a flat little-endian Float32 file `af_heart.f32` plus a text file `af_heart.rows` containing `N`. Copy both into `EchoCore/Resources/`. Document the exact source + sha256 in a comment in `KokoroVoicePack.swift`.

- [ ] **Step 1: Write the failing test** (clamp semantics match `voice_embedding_for_phoneme_string`).

```swift
// EchoTests/KokoroVoicePackTests.swift
import Testing
@testable import EchoCore

@Test func selectsClampedRowOf256() throws {
    let pack = try KokoroVoicePack(named: "af_heart")
    #expect(pack.refS(forPhonemeCount: 1).count == 256)       // row 0
    #expect(pack.refS(forPhonemeCount: 100_000).count == 256) // clamped to last row, no crash
}
```

- [ ] **Step 2: Run — verify it fails.** Expected: FAIL.

- [ ] **Step 3: Implement.** Load `<name>.f32` as `[Float]`, `rows = count/256`; `refS(forPhonemeCount:)` returns the 256-slice at `idx = max(0, min(n-1, rows-1))`. If the bundled blob is 1-D (256 floats), return it as-is (matches the Python `pack.dim()==1` branch).

- [ ] **Step 4: Run — verify it passes.** Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/KokoroVoicePack.swift EchoCore/Resources/af_heart.f32 EchoCore/Resources/af_heart.rows EchoTests/KokoroVoicePackTests.swift
git commit -m "feat(narration): af_heart voice pack + clamped refS selection"
```

---

## Phase 4 — Adapter + factory swap + renderVersion

### Task 4.1: KokoroFixedShapeEngine — the `TTSEngine` actor

**Files:**
- Create: `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift`
- Test: `EchoTests/KokoroFixedShapeEngineTests.swift`

**Interfaces:**
- Consumes: `NarrationModelStore` (3.x), `KokoroPhonemeVocab` (3.1), `KokoroG2P` (3.2), `KokoroVoicePack` (3.3), `KokoroPipeline.synthesize(inputIds:attentionMask:refS:speed:)`.
- Produces: `actor KokoroFixedShapeEngine: TTSEngine` with the exact `prepare()` / `synthesize(_:voice:)` contract from `TTSEngine.swift:33-36`, returning `TTSChunk(samples:sampleRate:24_000:duration:)`.

- [ ] **Step 1: Write the failing test** — vocab + voice glue produce well-formed pipeline inputs (engine logic without needing the model on the test host: factor the pure input-building into a testable function).

```swift
// EchoTests/KokoroFixedShapeEngineTests.swift
import Testing
@testable import EchoCore

@Test func buildsBosEosWrappedIdsAndMatchingAttentionMask() throws {
    let inputs = try KokoroFixedShapeEngine.buildInputs(text: "Hi.", voice: VoiceID("af_heart"))
    #expect(inputs.ids.first == 0 && inputs.ids.last == 0)        // BOS/EOS
    #expect(inputs.attentionMask.count == inputs.ids.count)        // mask aligns
    #expect(inputs.attentionMask.allSatisfy { $0 == 1 })          // no padding pre-bucket
    #expect(inputs.refS.count == 256)
}
```

- [ ] **Step 2: Run — verify it fails.** Expected: FAIL.

- [ ] **Step 3: Implement the actor.**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log
#if os(iOS) || os(macOS)
    import KokoroPipeline

    actor KokoroFixedShapeEngine: TTSEngine {
        private let logger = Logger(category: "KokoroFixed")
        private let g2p = KokoroG2P()
        private let vocab: KokoroPhonemeVocab
        private let voicePack: KokoroVoicePack
        private var pipeline: KokoroPipeline?
        private var initializationTask: Task<Void, Error>?

        init() {
            // Loaders are cheap (bundled resources); fail loudly if assets are missing.
            self.vocab = try! KokoroPhonemeVocab()
            self.voicePack = try! KokoroVoicePack(named: "af_heart")
        }

        struct PipelineInputs { let ids: [Int32]; let attentionMask: [Int32]; let refS: [Float] }

        /// Pure, testable input assembly (no model needed) — mirrors the Python path.
        static func buildInputs(text: String, voice: VoiceID) throws -> PipelineInputs {
            let g2p = KokoroG2P(); let vocab = try KokoroPhonemeVocab()
            let pack = try KokoroVoicePack(named: voice.rawValue)
            let phonemes = g2p.phonemes(for: text)
            let ids = vocab.ids(forPhonemes: phonemes)            // BOS/EOS wrapped
            let refS = pack.refS(forPhonemeCount: phonemes.count) // clamp by phoneme length
            return PipelineInputs(ids: ids, attentionMask: [Int32](repeating: 1, count: ids.count), refS: refS)
        }

        func prepare() async throws {
            if let task = initializationTask { try await task.value; return }
            let task = Task {
                let dir = try await NarrationModelStore.shared.ensureModels(progress: nil)
                self.pipeline = try KokoroPipeline(
                    modelsDirectory: dir,
                    buckets: NarrationModelStore.keptBucketSeconds,
                    linearWeights: NarrationModelStore.hnsfLinearWeights,
                    linearBias: NarrationModelStore.hnsfLinearBias)
            }
            initializationTask = task
            try await task.value
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try await prepare()
            guard let pipeline else { throw NarrationError.engineUnavailable }
            let inputs = try Self.buildInputs(text: text, voice: voice)
            let result = try pipeline.synthesize(
                inputIds: inputs.ids, attentionMask: inputs.attentionMask,
                refS: inputs.refS, speed: 1.0)
            return TTSChunk(
                samples: result.audio, sampleRate: 24_000,
                duration: Double(result.audio.count) / 24_000)
        }
    }
#endif
```

(Add `case engineUnavailable` to the existing narration error enum, or define `NarrationError` locally if none exists.)

- [ ] **Step 4: Run — verify the input-building test passes.**
Run: `make test-only FILTER=EchoTests/KokoroFixedShapeEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/KokoroFixedShapeEngine.swift EchoTests/KokoroFixedShapeEngineTests.swift
git commit -m "feat(narration): KokoroFixedShapeEngine (G2P→ids→refS→CoreML→TTSChunk)"
```

### Task 4.2: Swap the factory + bump renderVersion

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationEngineFactory.swift:15`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift:17`
- Modify: `EchoCore/Services/Narration/NarrationService.swift:227` (DEBUG smoke test)

- [ ] **Step 1: Swap `make()`.**
```swift
static func make() -> TTSEngine {
    KokoroFixedShapeEngine()   // was KokoroTTSEngine() — keep the old type in-tree for one-line revert
}
```

- [ ] **Step 2: Bump renderVersion** `4 → 5` and extend the comment (`v5 = fixed-shape mattmireles Kokoro CoreML + MisakiSwift G2P; different model/DSP/G2P → new bytes`).

- [ ] **Step 3:** Update the `#if DEBUG && os(iOS)` smoke test at `NarrationService.swift:227` to construct `KokoroFixedShapeEngine()`.

- [ ] **Step 4: Build both targets sequentially + run the full narration suite.**
Run: `make build-tests && make test-only FILTER=EchoTests/NarrationServiceTests` (then the new suites).
Expected: PASS (MockTTSEngine still injected in tests, so the swap doesn't break them); both app targets build.

- [ ] **Step 5: Commit.**
```bash
git add EchoCore/Services/Narration/NarrationEngineFactory.swift EchoCore/Services/Narration/NarrationFileNaming.swift EchoCore/Services/Narration/NarrationService.swift
git commit -m "feat(narration): swap engine to KokoroFixedShapeEngine; renderVersion v4→v5"
```

---

## Phase 5 — Verification + A14 gate relaxation + cleanup

### Task 5.1: macOS end-to-end verification (owner-driven)

- [ ] **Step 1:** Build + run the macOS app. Narrate the real "git-happens" EPUB via **Batch ▸ Narrate EPUB(s)…** (the path that wedged FluidAudio at ch7 on the M1 Pro).
- [ ] **Step 2: Acceptance:** all 16 chapters render (no vocoder ANE error / no wedge), the first-use model download succeeds, **Open** plays the result, read-along anchors materialize. Owner confirms audio quality.
- [ ] **Step 3:** Record RTF + first-launch compile time. Commit any fixes found.

### Task 5.2: iOS / A14 verification + gate relaxation (owner-driven)

**Files:** `EchoCore/Services/Narration/NarrationCapability.swift`, `EchoTests/NarrationCapabilityTests.swift`

- [ ] **Step 1: Temporary A14 test path.** Add a DEBUG-only override so narration is reachable on the A14 (e.g. a launch-argument or a `#if DEBUG` bypass of `isSupported`) WITHOUT yet changing the production gate. Build to the iPhone 12 Pro (`iPhone13,3`).
- [ ] **Step 2: Narrate a FULL book on the A14**, watching Console + `~/Library/Logs/DiagnosticReports` for a BNNS SIGTRAP / jetsam (the historical A14 failure). The mid-book chapters (≥7) are the gate.
- [ ] **Step 3 (branch on result):**
  - **A14 clean →** write the failing test, then relax the gate.
    ```swift
    // NarrationCapabilityTests.swift
    @Test func a14iPhoneNowSupported() {
        #expect(NarrationCapability.isSupported(modelIdentifier: "iPhone13,3"))  // A14, 12 Pro
    }
    ```
    Then change `isSupported` to return `true` for all iPhones (or lower the floor as the device evidence dictates), update the doc-comment to record that the fixed-shape model removed the A14 wedge, and remove the DEBUG override.
  - **A14 still wedges →** keep the A15+ gate, revert the DEBUG override, and record the failure (capture the `.ips`). The macOS swap still ships; A14 stays a follow-up.
- [ ] **Step 4: Run the capability tests + build.** Expected: PASS.
- [ ] **Step 5: Commit** the chosen outcome.
```bash
git add EchoCore/Services/Narration/NarrationCapability.swift EchoTests/NarrationCapabilityTests.swift
git commit -m "feat(narration): relax A15+ gate after A14 fixed-shape verification"   # or "test(narration): A14 still wedges — keep A15+ gate"
```

### Task 5.3: Cleanup + doc-sync

**Files:** `KokoroTTSEngine.swift`, FluidAudio link, `ARCHITECTURE.md`, `CODE_AUDIT_NARRATION.md`, `CHANGELOG.md`, memory `narration-feature.md`

- [ ] **Step 1 (only after BOTH platforms verified):** Delete `KokoroTTSEngine.swift`, remove the FluidAudio package from the iOS + macOS targets, and drop the now-unused `import FluidAudio` sites. Build both targets.
- [ ] **Step 2: Run the full suite.** Run: `make test`. Expected: green (modulo the documented pre-existing iOS-26-sim teardown abort).
- [ ] **Step 3: Doc-sync** (use the `doc-sync` skill): `ARCHITECTURE.md` (engine swap, Python-pipeline relationship), `CODE_AUDIT_NARRATION.md` (§3.1 A14 wedge CRUX → resolved-by-model-swap), `CHANGELOG.md` (user-facing: on-device narration now wedge-free; A14 re-enabled if Task 5.2 passed), and the `narration-feature` memory entry.
- [ ] **Step 4: Commit.**
```bash
git add -A
git commit -m "chore(narration): remove FluidAudio/KokoroTTSEngine; doc-sync fixed-shape swap"
```

---

## Top Risks (ranked) + mitigations

**Retired by Phase 0:** ~~vocab parity~~ (P0.1: 0 chars outside vocab), ~~espeak/GPL contamination~~ (P0.3: none), ~~does the Swift package wedge on M-series~~ (P0.2: 123 passes, no wedge).

1. **A14 still wedges** (Task 5.2) — the proof is M-series only; A-series ANE behavior for this pipeline is unverified, and A14 is the historical failure. *Mitigation: gate-relaxation is conditional on a real full-book A14 run; fallback keeps the A15+ gate, macOS ships regardless.*
2. **refS asset fidelity** (Task 3.3) — wrong `af_heart` matrix or wrong clamp = wrong voice. *Mitigation: convert from the exact validated source + sha256; clamp test; A/B the first Echo render against the P0 `swift_*.wav` clips.*
3. **First-launch compile cost** (~6 min on M1 Pro for the full set; pruned set is smaller) — bad UX on first narration. *Mitigation: `.mlmodelc` cached after first compile; "Preparing narration…" progress already exists; consider bundling precompiled `.mlmodelc` as a fast-follow.*
4. **MLX binary footprint** (accepted, P0.3) — MLX runtime + Metal lib + ~12 MB (us-only) resources added to the app. *Mitigation: drop `gb_*` resources; lexicon-only-G2P fast-follow documented in Task 3.2 if size becomes a concern. Verify the metallib bundles in the app target (not the bare-CLI failure mode) early in Task 3.2.*

## Self-Review notes

- Spec coverage: owner decisions (relax A15+ gate / P0-first / pruned runtime download) map to Tasks 5.2 / Phase 0 / Task 2 respectively. ✓
- Voice = Ava-only honored (single `af_heart` pack, no VoiceCatalog change). ✓
- Type consistency: `KokoroFixedShapeEngine.buildInputs` / `PipelineInputs` / `NarrationModelStore.keptBucketSeconds` / `hnsfLinearWeights` names are used identically across Tasks 2, 3, 4. ✓
- renderVersion bump appears once (Task 4.2) and is referenced in Global Constraints. ✓
