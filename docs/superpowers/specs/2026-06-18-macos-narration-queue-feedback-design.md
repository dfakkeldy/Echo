# macOS Narration: Prepare/Synthesis Feedback, Compiled-Model Persistence, and Queued-Item Removal

**Date:** 2026-06-18
**Status:** Design approved (brainstorm) — pending spec review → plan
**Branch context:** builds on the fixed-shape Kokoro swap (PR #86) + the static-MisakiSwift launch fix.

## Problem

Running fixed-shape narration on macOS shows **"Narrating chapter 1 of 9" for minutes with no feedback**, so it looks hung. Investigation (this session, on the M1 Pro) found:

1. **The wait is the engine's one-time `prepare()`, mislabeled as chapter 1.** `prepare()` runs *lazily inside the first `synthesize()`* and does two slow things that report nothing to the macOS batch UI:
   - **Download** ~850 MB of CoreML model packages via `NarrationModelStore.ensureModels(progress:)` — whose progress closure is currently passed `nil` (`KokoroFixedShapeEngine.swift:63`).
   - **Compile** ~20 `.mlpackage`s via `MLModel.compileModel` synchronously in `KokoroPipeline.init` (`KokoroPipeline.swift:213–259`). The pipeline's own doc comment says this "can take [minutes]."
2. **The compile repeats on every launch.** `KokoroPipeline.init` compiles into a **temporary** directory and never persists the resulting `.mlmodelc` (observed: fresh `kokoro_duration_t*.mlmodelc` written to `…/Data/tmp/` at run time). So the multi-minute compile is paid every launch, not just the first.
3. **No per-item queue removal.** The macOS narration queue (`batch_queue`) only supports `BatchQueueDAO.deleteCompleted()` (bulk). There is no way to remove a single queued file, and `MacBatchQueueView` has no per-row affordance.

## Goals

- Surface **real progress** during the one-time prepare (download %, then compile *N of total*) and an **accurate** per-chapter status during synthesis — on the macOS batch UI and (cheaply) iOS Now Playing.
- Compile the CoreML model set **once ever** by persisting the compiled `.mlmodelc`, so only the first run is slow.
- Let the user **remove a queued item** from the narration queue.

## Non-Goals

- Removing/cancelling an **in-progress, completed, or failed** queue item (decision: **queued-only**).
- Deleting rendered audio when removing a queue item (decision: **non-destructive** — job row only).
- A within-chapter synthesis sub-bar (decision: **per-chapter** granularity is enough).
- Any change to engine selection, the iOS A14 gate, or upstream model assets.

## Decisions locked (brainstorm)

| Decision | Choice |
|---|---|
| Remove scope | **Queued items only** |
| Rendered audio on removal | **Keep the rendered book** (job row only) |
| Primary surface | macOS batch; iOS Now Playing enriched cheaply via existing `NarrationState` |
| Synthesis granularity | Per-chapter ("Narrating 3 of 9") |

---

## Workstream A — Prepare/synthesis feedback

### Seam: an optional progress overload on `TTSEngine`

`EchoCore/Services/Narration/TTSEngine.swift`. Backward-compatible: the no-arg `prepare()` stays the protocol requirement; a protocol-extension overload defaults to it, so FluidAudio (`KokoroTTSEngine`) and `MockTTSEngine` need no changes.

```swift
protocol TTSEngine: Sendable {
    func prepare() async throws
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
}

extension TTSEngine {
    // Engines that can report prepare progress override this; the rest inherit
    // the no-op default so existing call sites and test doubles are unaffected.
    func prepare(progress: @Sendable (NarrationPrepareProgress) -> Void) async throws {
        try await prepare()
    }
}

enum NarrationPrepareProgress: Sendable, Equatable {
    case downloadingModels(fraction: Double)   // 0…1
    case compilingModels(done: Int, total: Int)
    case ready
}
```

### Engine wiring: `KokoroFixedShapeEngine.prepare(progress:)`

Override the overload; map each phase into `NarrationPrepareProgress`:
- `NarrationModelStore.ensureModels(progress: { progress(.downloadingModels(fraction: $0)) })` — the download closure that is currently `nil`.
- `KokoroPipeline.init(…, compileProgress: { done, total in progress(.compilingModels(done: done, total: total)) })` — see Workstream B.
- Emit `.ready` once the pipeline is built.
- The no-arg `prepare()` becomes `try await prepare(progress: { _ in })`.

Prepare stays on the existing background `Task` (already off the main actor), so this adds reporting only — it does not change threading.

### macOS surface: `MacBatchProcessingService`

Call `prepare(progress:)` **explicitly before** the chapter loop (the service/engine is created once via `makeService()` and reused across chapters), mapping `NarrationPrepareProgress` onto the existing batch progress callback `progress(.transcribing, fraction, message)`.

**Progress must stay monotonic.** The existing narrate loop already drives the batch bar `0.1 + 0.85·n/count` (`MacBatchProcessingService.swift:289`). If prepare filled `0…1.0`, the bar would jump *backwards* to `0.1` when synthesis starts. So prepare occupies the item's first slice and the chapter loop is rebased to start after it:

- Prepare drives batch fraction `0 → 0.15` (the text carries the real granularity, so the bar still creeps while the detail updates):
  - `.downloadingModels(f)` → `"Preparing voice models (one-time, ~850 MB)… \(Int(f*100))%"`, fraction `0 → 0.075`.
  - `.compilingModels(done, total)` → `"Compiling voice models… \(done) of \(total)"`, fraction `0.075 → 0.15`.
- Chapter loop rebased to `0.15 + 0.80·n/count` (was `0.1 + 0.85·n/count`), so `"Narrating chapter N of M"` continues smoothly upward from where prepare left off.

On the retry-with-fresh-engine path, prepare runs again but is fast (models cached + compiled per Workstream B), so the prepare band passes near-instantly.

The progress→status-string mapping is extracted as a **pure function** (`NarrationPrepareStatus.batchMessage(for:) -> (fraction: Double, text: String)`) so it is unit-testable without the engine.

### iOS surface: `NarrationState`

Add `NarrationState.Phase.preparingEngine`. The iOS render path calls `prepare(progress:)` before rendering and maps each `NarrationPrepareProgress` to `state.update(phase: .preparingEngine, …)`, so the existing "Preparing narration…" Now Playing subtitle gains download/compile detail. Minimal change; no new UI.

### Tests (A)

- `NarrationPrepareStatus.batchMessage(for:)` mapping: each case → expected fraction band + text.
- `NarrationState` transitions through `.preparingEngine`.

---

## Workstream B — Persist compiled models

### `KokoroPipeline.init`

Add two optional parameters (defaults preserve today's behavior, so the `ios-bench`/upstream callers are unchanged):

```swift
public init(
    modelsDirectory: URL,
    compiledModelsDirectory: URL? = nil,   // nil → compile to temp (current behavior)
    buckets: [Int] = PipelineConstants.defaultBuckets,
    linearWeights: [Float],
    linearBias: Float,
    compileProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
) throws
```

Factor the repeated `MLModel(contentsOf: MLModel.compileModel(at: pkg), configuration:)` (four loops) through one helper:

```swift
// Compile-once: reuse a cached .mlmodelc when present; otherwise compile and
// MOVE the result into the cache. On any cache-write failure, fall back to the
// freshly-compiled temp URL so a full/read-only disk can't break narration.
private static func loadModel(
    package: URL, cacheDir: URL?, config: MLModelConfiguration
) throws -> MLModel
```

Total model count (`durationChoices.count + f0 + decoderPre + generator`) is known up front, so `compileProgress(done, total)` fires as each model loads (cache hit or compile).

### Cache location & invalidation

`KokoroFixedShapeEngine` passes `compiledModelsDirectory = NarrationModelStore.modelsDirectory()/compiled` (created if needed). Because that sits under the `renderVersion`-stamped `Models/kokoro-fixed-v5/` subdir, the existing stale-model sweep on a `renderVersion` bump drops the compiled cache too — **no separate invalidation logic**.

### Tests (B)

The persistence *decision* is extracted as a pure helper that takes the compile step as a closure, e.g. `ensureCompiled(name:cacheDir:compile:) -> URL`. Unit test: a cache **miss** invokes the compile closure exactly once and writes the cache; a cache **hit** skips it. (Honest limit: real `MLModel.compileModel` against a live model is not unit-tested — that is covered by the on-device run.)

---

## Workstream C — Remove a queued item (queued-only, non-destructive)

### DAO

`Shared/Database/DAOs/BatchQueueDAO.swift`:

```swift
/// Removes a single queue entry. Guarded to `queued` so a row that has already
/// started (or finished) is never yanked out from under the runner; deleting a
/// non-queued id is a no-op. Only the queue row is touched — any rendered audio,
/// tracks, and anchors for the book are left intact.
func deleteQueued(id: Int64) throws
```

### UI

`Echo macOS/Views/MacBatchQueueView.swift`: a **"Remove from Queue"** affordance (context menu + trailing control) shown **only when `item.status == .queued`**, calling `deleteQueued(id:)` then refreshing. `queuePosition` gaps left by a delete are harmless (`nextQueued()` orders by position).

### Tests (C)

`BatchQueueDAO` via `DatabaseService(inMemory:)`: enqueue three, `deleteQueued` the middle one → it is gone, the other two remain; `deleteQueued` on a `completed`/`transcribing` id is a no-op.

---

## Error handling

- **A:** progress is best-effort and can never fail a render; `ensureModels` still throws on a genuine download failure exactly as today.
- **B:** a compile-cache write/move failure logs and falls back to the freshly-compiled temp URL — narration still works, it just doesn't persist that model this run.
- **C:** `deleteQueued` is idempotent and status-guarded; a row that started between render and tap is a no-op.

## Files touched

- `EchoCore/Services/Narration/TTSEngine.swift` — overload + `NarrationPrepareProgress`
- `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift` — wire progress + compiled-cache dir
- `EchoCore/Services/Narration/NarrationState.swift` — `.preparingEngine`
- `EchoCore/Services/Narration/NarrationModelStore.swift` — expose `modelsDirectory()/compiled` (download progress closure already exists)
- `ThirdParty/KokoroPipeline/Sources/KokoroPipeline/KokoroPipeline.swift` — compiled cache + `compileProgress`
- `Echo macOS/Services/MacBatchProcessingService.swift` — explicit `prepare(progress:)` + status mapping
- iOS Now Playing / narration render path — `.preparingEngine` subtitle (minimal)
- `Shared/Database/DAOs/BatchQueueDAO.swift` — `deleteQueued(id:)`
- `Echo macOS/Views/MacBatchQueueView.swift` — remove affordance
- Tests: prepare-status mapping, KokoroPipeline compiled-cache helper, `BatchQueueDAO.deleteQueued`

## Sequencing

Three independent, separately-shippable workstreams. Suggested order: **C** (small, isolated) → **A** (the feedback) → **B** (the perf fix). One implementation plan, three phases. Workstream B is the only edit to the vendored `KokoroPipeline` package — kept small and well-commented as the sole upstream divergence.

## Out-of-session verification

On-device confirmation stays owner-driven: first run shows download→compile progress; **second** launch is fast (compiled cache hit); a queued file can be removed before it starts.
