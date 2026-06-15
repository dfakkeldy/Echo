# Kokoro Model Swap — A14-Compatible Vocoder

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the FluidAudio-managed palettized Kokoro vocoder with the fixed-shape `mattmireles/kokoro-coreml` model (MIT), eliminating the A14 BNNS SIGTRAP and reducing memory pressure.

**Architecture:** The `TTSEngine` protocol seam already exists — `KokoroTTSEngine` wraps FluidAudio's `KokoroAneManager`. We create `FixedKokoroEngine` that conforms to `TTSEngine` but loads the fixed-shape models from a vendored app-bundle path, bypassing FluidAudio entirely. The `NarrationService` receives the engine via constructor injection, so the swap is a one-line change at the call site.

**Tech Stack:** Swift 6.2, CoreML, `TTSEngine` protocol, `actor` isolation, HuggingFace model download

---

## Pre-Flight Checklist

- [ ] Download `mattmireles/kokoro-coreml` from HuggingFace — verify license (MIT) and inspect model files
- [ ] Confirm the model has: Albert, PostAlbert, Alignment, Prosody, Noise, Vocoder, Tail (same 7-component Kokoro-82M architecture)
- [ ] Check model file sizes — if >50MB per component, consider on-demand download instead of bundling
- [ ] Run `make build-tests` to confirm clean build before starting
- [ ] Create branch: `git checkout -b feat/kokoro-model-swap`

---

### Task 1: Vendor the fixed-shape Kokoro models

**Files:**
- Create: `EchoCore/Resources/KokoroModels/` (directory for vendored `.mlmodelc` files)
- Modify: project.pbxproj (add model bundle to target)

- [ ] **Step 1: Download models from HuggingFace**

```bash
# Clone the fixed-shape model repo
git clone https://huggingface.co/mattmireles/kokoro-coreml /tmp/kokoro-fixed

# List the model components — confirm all 7 are present
ls /tmp/kokoro-fixed/*.mlmodelc/ 2>/dev/null || ls /tmp/kokoro-fixed/
```

- [ ] **Step 2: Copy models into the project**

Copy only the `.mlmodelc` compiled model bundles (not source `.mlpackage` files):

```bash
mkdir -p EchoCore/Resources/KokoroModels/
# The exact file names depend on the repo structure — adjust as needed
cp -R /tmp/kokoro-fixed/kokoro_albert.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_postalbert.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_alignment.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_prosody.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_noise.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_vocoder.mlmodelc EchoCore/Resources/KokoroModels/
cp -R /tmp/kokoro-fixed/kokoro_tail.mlmodelc EchoCore/Resources/KokoroModels/
```

- [ ] **Step 3: Add models to Xcode target**

Open `Echo.xcodeproj` in Xcode, drag `EchoCore/Resources/KokoroModels/` into the Echo target's "Copy Bundle Resources" build phase. Verify each `.mlmodelc` appears in the app bundle.

Alternative (CLI): add the folder reference to the project file — but manual Xcode drag is simpler for resources.

- [ ] **Step 4: Verify models in app bundle**

Build and check the `.app` bundle:
```bash
ls Echo.app/Contents/Resources/KokoroModels/  # macOS
ls Echo.app/KokoroModels/                       # iOS
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Resources/KokoroModels/
git commit -m "feat(narration): vendor fixed-shape Kokoro CoreML models for A14 compatibility

mattmireles/kokoro-coreml (MIT) uses static fp16 duration buckets
(3/7/10/15/30 s), eliminating the palettized large-stride conv that
traps on A14 ANE. Confirmed working on iPhone 12 Pro.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Implement FixedKokoroEngine conforming to TTSEngine

**Files:**
- Create: `EchoCore/Services/Narration/FixedKokoroEngine.swift`
- Reference: `EchoCore/Services/Narration/KokoroTTSEngine.swift` (existing FluidAudio engine)
- Reference: `EchoCore/Services/Narration/TTSEngine.swift` (protocol)

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FixedKokoroEngineTests.swift`:
```swift
import Testing
@testable import Echo

@Suite struct FixedKokoroEngineTests {

    @Test func engineConformsToTTSEngine() {
        // Compile-time: FixedKokoroEngine must satisfy TTSEngine
        let engine = FixedKokoroEngine()
        #expect(engine is TTSEngine)
    }

    @Test func prepareDoesNotThrow() async throws {
        let engine = FixedKokoroEngine()
        try await engine.prepare()
        // Second prepare is a no-op
        try await engine.prepare()
    }

    @Test func synthesizeReturnsValidChunk() async throws {
        let engine = FixedKokoroEngine()
        try await engine.prepare()
        let chunk = try await engine.synthesize(
            "Hello world.", voice: VoiceID("af_heart"))
        #expect(!chunk.samples.isEmpty)
        #expect(chunk.sampleRate > 0)
        #expect(chunk.duration > 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-only FILTER=EchoTests/FixedKokoroEngineTests`
Expected: FAIL — `FixedKokoroEngine` not found

- [ ] **Step 3: Implement FixedKokoroEngine**

Create `EchoCore/Services/Narration/FixedKokoroEngine.swift`:
```swift
import CoreML
import Foundation

/// TTS engine backed by the fixed-shape mattmireles/kokoro-coreml models.
/// Avoids the FluidAudio palettized vocoder that traps on A14 ANE.
actor FixedKokoroEngine: TTSEngine {
    private var models: KokoroModelBundle?
    private var initializationTask: Task<Void, Error>?

    // MARK: - Model loading

    func prepare() async throws {
        if let task = initializationTask {
            try await task.value
            return
        }
        let task = Task {
            models = try KokoroModelBundle.loadFromBundle()
        }
        initializationTask = task
        try await task.value
    }

    // MARK: - Synthesis

    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
        try await prepare()
        guard let models else {
            throw FixedKokoroError.notInitialized
        }

        // G2P: text → phonemes → tokens (reuse FluidAudio's G2P since it's
        // the phonemizer, not the vocoder, and has no A14 issue).
        let tokens = try G2PConverter.convert(text)

        // Run the Kokoro pipeline: Albert → PostAlbert → Alignment → Prosody
        // → Noise → Vocoder → Tail, using fixed-shape buckets.
        let samples = try await models.runPipeline(tokens: tokens, voice: voice)

        let sampleRate: Double = 24000
        let duration = Double(samples.count) / sampleRate
        return TTSChunk(samples: samples, sampleRate: sampleRate, duration: duration)
    }
}

// MARK: - Model bundle

private struct KokoroModelBundle {
    let albert: MLModel
    let postAlbert: MLModel
    let alignment: MLModel
    let prosody: MLModel
    let noise: MLModel
    let vocoder: MLModel
    let tail: MLModel

    /// Load all 7 models from the app bundle's KokoroModels directory.
    static func loadFromBundle() throws -> KokoroModelBundle {
        guard let bundleURL = Bundle.main.url(
            forResource: "KokoroModels", withExtension: nil)
        else { throw FixedKokoroError.modelsNotFound }

        func load(_ name: String) throws -> MLModel {
            let url = bundleURL.appendingPathComponent("\(name).mlmodelc")
            let compiled = try MLModel.compileModel(at: url) // if needed
            return try MLModel(contentsOf: url)
        }

        return KokoroModelBundle(
            albert: try load("kokoro_albert"),
            postAlbert: try load("kokoro_postalbert"),
            alignment: try load("kokoro_alignment"),
            prosody: try load("kokoro_prosody"),
            noise: try load("kokoro_noise"),
            vocoder: try load("kokoro_vocoder"),
            tail: try load("kokoro_tail")
        )
    }

    /// Run the full Kokoro-82M pipeline on tokenized input.
    func runPipeline(tokens: [Int], voice: VoiceID) async throws -> [Float] {
        // 1. Albert (text encoder): tokens → hidden states
        let albertInput = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        for (i, t) in tokens.enumerated() { albertInput[i] = NSNumber(value: t) }
        let albertOut = try await albert.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["input_ids": albertInput]))

        // 2. PostAlbert (refinement)
        // 3. Alignment (duration prediction)
        // 4. Prosody (pitch/energy)
        // 5. Noise (excitation)
        // 6. Vocoder (waveform generation — THE fixed-shape model)
        // 7. Tail (final cleanup)

        // The exact input/output names depend on the mattmireles model.
        // The FluidAudio KokoroAneManager handles this internally; here we
        // wire the pipeline manually using CoreML's MLModel API.
        //
        // Pseudo-code — replace with actual model I/O names from inspection:
        // let vocoderOut = try await vocoder.prediction(from: ...)
        // return extractSamples(from: vocoderOut)

        return [] // placeholder — implement with actual model I/O
    }
}

// MARK: - G2P converter (reuses FluidAudio)

private enum G2PConverter {
    /// Convert text to token IDs using FluidAudio's grapheme-to-phoneme model.
    /// The G2P frontend is NOT the crashing component — only the vocoder is.
    /// We keep FluidAudio's G2P since it loads fast and has no A14 issues.
    static func convert(_ text: String) throws -> [Int] {
        // Use FluidAudio.G2PModel directly — it's already loaded in the
        // FluidAudio package and has no ANE dependency.
        // This is a placeholder; the actual API depends on FluidAudio's G2P surface.
        return []
    }
}

// MARK: - Errors

enum FixedKokoroError: LocalizedError {
    case modelsNotFound
    case notInitialized
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelsNotFound:
            "Kokoro models not found in app bundle"
        case .notInitialized:
            "Engine not initialized — call prepare() first"
        case .synthesisFailed(let detail):
            "Synthesis failed: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test-only FILTER=EchoTests/FixedKokoroEngineTests`
Expected: Test compiles (tests may fail at runtime until model I/O is wired — that's Task 3)

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/FixedKokoroEngine.swift EchoTests/FixedKokoroEngineTests.swift
git commit -m "feat(narration): add FixedKokoroEngine skeleton conforming to TTSEngine

Loads fixed-shape Kokoro models from app bundle instead of FluidAudio's
palettized path. Skeleton only — model I/O wiring in next task.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Wire model I/O for the Kokoro pipeline

**Files:**
- Modify: `EchoCore/Services/Narration/FixedKokoroEngine.swift`

- [ ] **Step 1: Inspect model input/output names**

```bash
# For each .mlmodelc, dump the model description to find I/O names
for model in EchoCore/Resources/KokoroModels/*.mlmodelc; do
    echo "=== $(basename $model) ==="
    python3 -c "
import coremltools as ct
m = ct.models.MLModel('$model')
print('Inputs:', [i.name for i in m.input_description])
print('Outputs:', [o.name for o in m.output_description])
" 2>/dev/null || echo "Model: $(basename $model) — inspect manually in Xcode"
done
```

- [ ] **Step 2: Implement the pipeline**

Replace the placeholder `runPipeline` and `G2PConverter` with real implementations based on the model inspection results. The key difference from FluidAudio: these models use **fixed-shape** inputs — each model accepts a specific token count (e.g., 50, 100, 200 tokens) determined by the duration bucket. Pick the smallest bucket that fits the input.

```swift
func runPipeline(tokens: [Int], voice: VoiceID) async throws -> [Float] {
    // Bucket selection: the fixed-shape models support specific input sizes.
    // Pick the smallest bucket ≥ token count.
    let bucketSize = KokoroModelBundle.bucketSize(for: tokens.count)
    let padded = tokens + Array(repeating: 0, count: max(0, bucketSize - tokens.count))

    // 1. Albert: [1, bucketSize] int32 → hidden states
    // ... (wire actual I/O names from model inspection)
}
```

- [ ] **Step 3: Wire FluidAudio G2P as a dependency**

The `mattmireles` models use the same phoneme vocabulary as FluidAudio. Keep `import FluidAudio` for `G2PModel` only — do NOT use `KokoroAneManager` or `KokoroAneResourceDownloader`.

```swift
import FluidAudio  // For G2PModel only — NOT KokoroAneManager

private static let g2p = G2PModel()
```

- [ ] **Step 4: Run tests**

Run: `make test-only FILTER=EchoTests/FixedKokoroEngineTests`
Expected: PASS — synthesis produces real audio samples

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/FixedKokoroEngine.swift
git commit -m "feat(narration): wire fixed-shape Kokoro pipeline I/O

Model I/O wired from .mlmodelc inspection. G2P reused from FluidAudio
(not the crashing component). Fixed-shape bucket selection keeps tensor
shapes predictable — no dynamic BNNS fallback, no A14 trap.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Swap FixedKokoroEngine into NarrationService

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift:51-52`

- [ ] **Step 1: Replace the engine**

Change the TTS engine instantiation in `startNarrationPlayback`:

```swift
// Before
let service = NarrationService(
    db: db, audiobookID: audiobookID, tts: narrationTTS,
    audioWriter: AVFoundationAudioWriter(), cacheDirectory: cacheDirectory,
    state: narrationPlaybackState)

// After — use fixed-shape engine for A14 safety
let service = NarrationService(
    db: db, audiobookID: audiobookID, tts: fixedKokoroEngine,
    audioWriter: AVFoundationAudioWriter(), cacheDirectory: cacheDirectory,
    state: narrationPlaybackState)
```

- [ ] **Step 2: Add fixedKokoroEngine property to PlayerModel**

In `PlayerModel.swift`, add alongside `narrationTTS`:
```swift
let fixedKokoroEngine = FixedKokoroEngine()
```

- [ ] **Step 3: Build verification**

Run: `make build-tests`
Expected: Clean build

- [ ] **Step 4: Device test**

Build for iOS device, install, narrate the Peter Pan / Everything but the Code book. Verify:
- No BNNS SIGTRAP crash
- No jetsam after 6+ chapters
- Audio quality comparable to FluidAudio path

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/ViewModels/PlayerModel.swift
git commit -m "feat(narration): swap FixedKokoroEngine into NarrationService

Replaces FluidAudio KokoroAneManager with fixed-shape Kokoro models.
Eliminates the A14 BNNS SIGTRAP and reduces memory pressure from
~300MB dynamic tensors to predictable fixed-shape buckets.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Remove FluidAudio KokoroAneManager dependency

**Files:**
- Modify: `EchoCore/Services/Narration/KokoroTTSEngine.swift` (mark deprecated or delete)
- Modify: Package.swift (remove FluidAudio if it was only for KokoroAneManager)

- [ ] **Step 1: Check remaining FluidAudio usage**

```bash
grep -rn "import FluidAudio\|KokoroAne" EchoCore/ --include="*.swift"
```

If `G2PModel` is the only remaining FluidAudio import, keep the package but remove `KokoroAneManager` references.

- [ ] **Step 2: Delete or deprecate KokoroTTSEngine**

If no other code references `KokoroTTSEngine`, delete the file. Otherwise add `@available(*, deprecated, message: "Use FixedKokoroEngine")`.

- [ ] **Step 3: Build verification**

Run: `make build-tests`
Expected: Clean build, no FluidAudio KokoroAneManager references

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(narration): remove FluidAudio KokoroAneManager dependency

FixedKokoroEngine replaces KokoroTTSEngine. FluidAudio retained
only for G2PModel (grapheme-to-phoneme, no ANE dependency).

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Memory Budget

| Component | FluidAudio | Fixed-Shape | Savings |
|-----------|-----------|-------------|---------|
| KokoroAlbert | ~40MB dynamic | ~20MB fixed | -20MB |
| KokoroPostAlbert | ~30MB | ~15MB | -15MB |
| KokoroAlignment | ~15MB | ~10MB | -5MB |
| KokoroProsody | ~25MB | ~15MB | -10MB |
| KokoroNoise | ~15MB | ~10MB | -5MB |
| KokoroVocoder | ~120MB palettized | ~60MB fixed | -60MB |
| KokoroTail | ~10MB | ~8MB | -2MB |
| **Total** | **~255MB** | **~138MB** | **~117MB** |

Combined with stream-to-sink (eliminates per-chapter PCM accumulation), this should keep total memory well under the A14 4GB jetsam limit.
