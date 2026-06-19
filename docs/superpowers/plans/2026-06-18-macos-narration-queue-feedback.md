# macOS Narration: Prepare Feedback, Compiled-Model Persistence & Queued-Item Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make macOS fixed-shape narration show honest progress during the one-time model download + CoreML compile, compile the models once ever (not every launch), and let the user remove a still-queued item from the batch queue.

**Architecture:** Three independent workstreams. Removal is a guarded DAO delete + a `MacBatchQueueView` affordance. Feedback adds a backward-compatible `TTSEngine.prepare(progress:)` overload that the macOS batch stage calls explicitly *before* the chapter loop. Persistence routes `KokoroPipeline`'s `MLModel.compileModel` output through a cache under Application Support.

**Tech Stack:** Swift 6.2, SwiftUI, GRDB, CoreML, Swift Testing. Targets: `Echo` (iOS), `Echo macOS`, the vendored `KokoroPipeline` SwiftPM package.

**Spec:** `docs/superpowers/specs/2026-06-18-macos-narration-queue-feedback-design.md`

## Global Constraints

- **Removal scope:** queued items only; **non-destructive** — delete the `batch_queue` row only, never rendered audio/tracks/anchors.
- **Backward compatibility:** `TTSEngine.prepare()` stays the protocol requirement; the new `prepare(progress:)` is a protocol-extension overload defaulting to `prepare()`, so `KokoroTTSEngine` (FluidAudio) and `MockTTSEngine` are untouched.
- **`KokoroPipeline.init` new params default to nil/no-op** so the `ios-bench`/upstream callers are unchanged.
- **Monotonic progress:** prepare occupies the batch bar `0 → 0.15`; the narrate chapter loop is rebased to `0.15 + 0.80·n/count` (was `0.1 + 0.85·n/count`).
- **Compiled cache is `renderVersion`-keyed:** it lives under the `Models/kokoro-fixed-v5/` subdir, so the existing stale-model sweep invalidates it on a `renderVersion` bump — no separate invalidation.
- **Synthesis granularity:** per-chapter ("Narrating 3 of 9"); no within-chapter sub-bar.
- **Build/RAM rules (16 GB machine):** every `xcodebuild` uses `-jobs 5`, never parallel testing, never two `xcodebuild` concurrently.
- **Commits:** Conventional Commits. The SwiftFormat PostToolUse hook reflows the whole file on edit — after each edit confirm the SPDX header is still line 1.

**Sequence (dependency order):** Task 1–2 (Removal, independent) → Task 3 (protocol + mapping) → Task 4 (KokoroPipeline cache) → Task 5 (engine wiring) → Task 6 (macOS surface) → Task 7 (iOS surface).

---

### Task 1: `BatchQueueDAO.deleteQueued(id:)`

**Files:**
- Modify: `Shared/Database/DAOs/BatchQueueDAO.swift`
- Test: `EchoTests/BatchQueueDAOTests.swift`

**Interfaces:**
- Produces: `func deleteQueued(id: Int64) throws` on `BatchQueueDAO` — deletes the row only if its `status == .queued`; a non-queued id is a no-op.

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/BatchQueueDAOTests.swift` (inside the existing `@Suite struct`):

```swift
@Test func deleteQueuedRemovesOnlyTheQueuedRow() throws {
    let dbService = DatabaseService(inMemory: true)
    let dao = BatchQueueDAO(db: dbService.writer)
    func rec(_ name: String, _ status: BatchItemStatus) -> BatchQueueRecord {
        BatchQueueRecord(
            audiobookID: name, sourceBookmark: Data(), companionBookmark: nil,
            displayName: name, queuePosition: 0, status: status, progress: 0,
            enqueuedAt: "2026-06-18T00:00:00Z")
    }
    let a = try dao.enqueue(rec("a", .queued))
    _ = try dao.enqueue(rec("b", .queued))
    let c = try dao.enqueue(rec("c", .completed))

    try dao.deleteQueued(id: a.id!)
    #expect(try dao.allItems().map(\.audiobookID) == ["b", "c"])  // a gone, order kept

    // Guard: deleting a non-queued id is a no-op.
    try dao.deleteQueued(id: c.id!)
    #expect(try dao.allItems().count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/BatchQueueDAOTests`
Expected: FAIL — `value of type 'BatchQueueDAO' has no member 'deleteQueued'`.

- [ ] **Step 3: Write minimal implementation**

In `Shared/Database/DAOs/BatchQueueDAO.swift`, add after `deleteCompleted()`:

```swift
/// Removes a single queue entry, but only while it is still `queued` — a row the
/// runner has already started (or finished) is left untouched, and deleting a
/// non-queued id is a no-op. Only the queue row is removed; rendered audio,
/// tracks, and anchors for the book are not touched.
func deleteQueued(id: Int64) throws {
    _ = try db.write { db in
        try BatchQueueRecord
            .filter(Column("id") == id && Column("status") == BatchItemStatus.queued.rawValue)
            .deleteAll(db)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test-only FILTER=EchoTests/BatchQueueDAOTests`
Expected: PASS (all tests in the suite).

- [ ] **Step 5: Commit**

```bash
git add "Shared/Database/DAOs/BatchQueueDAO.swift" "EchoTests/BatchQueueDAOTests.swift"
git commit -m "feat(narration): add BatchQueueDAO.deleteQueued for queued-only removal"
```

---

### Task 2: Remove affordance in the macOS queue UI

**Files:**
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift` (add `removeQueued`)
- Modify: `Echo macOS/Views/MacBatchQueueView.swift` (row affordance)

**Interfaces:**
- Consumes: `BatchQueueDAO.deleteQueued(id:)` (Task 1).
- Produces: `MacBatchProcessingService.removeQueued(_ item: BatchQueueRecord)`.

> No unit test: `MacBatchProcessingService`/SwiftUI views live in the macOS app target, which `EchoTests` (iOS sim) cannot import. The delete logic is covered by Task 1; this task is build-verified.

- [ ] **Step 1: Add the service method**

In `Echo macOS/Services/MacBatchProcessingService.swift`, add right after `clearCompleted()`:

```swift
/// Removes a still-queued item from the queue (no-op if the runner has already
/// started it). Only the queue row is deleted — any rendered chapters for the
/// book stay in the library. Mirrors `clearCompleted()`: DAO write then refresh.
func removeQueued(_ item: BatchQueueRecord) {
    guard let id = item.id else { return }
    try? dao.deleteQueued(id: id)
    refresh()
}
```

- [ ] **Step 2: Pass an `onRemove` to the row for queued items**

In `Echo macOS/Views/MacBatchQueueView.swift`, replace the `MacBatchQueueRow(...)` call inside the `List` with:

```swift
MacBatchQueueRow(
    item: item,
    onOpen: (item.kind == .narrate
        && (item.status == .completed || item.status == .failed)
        && service.hasRenderedTracks(for: item.audiobookID))
        ? {
            player.loadNarratedBook(audiobookID: item.audiobookID)
            dismiss()
        }
        : nil,
    // Only a not-yet-started item can be pulled from the queue.
    onRemove: item.status == .queued ? { service.removeQueued(item) } : nil)
```

- [ ] **Step 3: Render the remove control in the row**

In the same file, in `private struct MacBatchQueueRow`, add the property and the control. Add after `var onOpen: (() -> Void)? = nil`:

```swift
/// Non-nil for a queued item: removes it from the queue.
var onRemove: (() -> Void)? = nil
```

Then replace the trailing `if let onOpen { … }` block in `body` with:

```swift
if let onOpen {
    Spacer()
    Button("Open", action: onOpen)
        .buttonStyle(.borderless)
}
if let onRemove {
    Spacer()
    Button(role: .destructive, action: onRemove) {
        Image(systemName: "minus.circle")
    }
    .buttonStyle(.borderless)
    .help("Remove from Queue")
}
```

And add a context menu to the row by appending to `body`'s outer `HStack` (after `.padding(.vertical, 4)`):

```swift
.contextMenu {
    if let onRemove {
        Button("Remove from Queue", systemImage: "minus.circle", role: .destructive, action: onRemove)
    }
}
```

- [ ] **Step 4: Build the macOS app to verify it compiles**

Run: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64' -jobs 5 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add "Echo macOS/Services/MacBatchProcessingService.swift" "Echo macOS/Views/MacBatchQueueView.swift"
git commit -m "feat(narration): remove a queued item from the macOS batch queue"
```

---

### Task 3: `NarrationPrepareProgress` + `prepare(progress:)` overload + status mapping

**Files:**
- Modify: `EchoCore/Services/Narration/TTSEngine.swift`
- Test: `EchoTests/NarrationPrepareStatusTests.swift` (create)

**Interfaces:**
- Produces:
  - `enum NarrationPrepareProgress: Sendable, Equatable { case downloadingModels(fraction: Double); case compilingModels(done: Int, total: Int); case ready }`
  - `extension TTSEngine { func prepare(progress: @Sendable (NarrationPrepareProgress) -> Void) async throws }` (default → `prepare()`)
  - `enum NarrationPrepareStatus { static func batch(for: NarrationPrepareProgress) -> (fraction: Double, message: String) }`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NarrationPrepareStatusTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationPrepareStatusTests {
    @Test func mapsMonotonicallyIntoTheReservedFirstBand() {
        let d0 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 0))
        let d1 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 1))
        let c0 = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 20))
        let c1 = NarrationPrepareStatus.batch(for: .compilingModels(done: 20, total: 20))
        let ready = NarrationPrepareStatus.batch(for: .ready)

        #expect(d0.fraction == 0)
        #expect(d1.fraction <= c0.fraction)   // download band ends at/below compile band start
        #expect(c1.fraction <= ready.fraction)
        #expect(ready.fraction == 0.15)       // never exceeds the reserved prepare band
        #expect(d1.message.contains("100%"))
        #expect(c0.message == "Compiling voice models… 0 of 20")
    }

    @Test func compileTotalZeroDoesNotDivideByZero() {
        let s = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 0))
        #expect(s.fraction.isFinite)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationPrepareStatusTests`
Expected: FAIL — `cannot find 'NarrationPrepareStatus' in scope`.

- [ ] **Step 3: Write the implementation**

In `EchoCore/Services/Narration/TTSEngine.swift`, add below the existing `protocol TTSEngine` declaration:

```swift
/// One step of the engine's one-time `prepare()` — surfaced so the UI can show
/// real progress instead of sitting on "Narrating chapter 1" while the model set
/// downloads and the CoreML graphs compile.
enum NarrationPrepareProgress: Sendable, Equatable {
    case downloadingModels(fraction: Double)   // 0…1
    case compilingModels(done: Int, total: Int)
    case ready
}

extension TTSEngine {
    /// Default: no progress. Engines that can report it (KokoroFixedShapeEngine)
    /// override this; FluidAudio + MockTTSEngine inherit the no-op so existing
    /// call sites and test doubles are unaffected.
    func prepare(progress: @Sendable (NarrationPrepareProgress) -> Void) async throws {
        try await prepare()
    }
}

/// Pure mapping from a prepare step to the macOS batch item's (fraction, message).
/// Prepare occupies the item's first 0→0.15 band so the bar stays monotonic with
/// the chapter loop (rebased to 0.15 + 0.80·n/count). Download fills 0→0.075,
/// compile fills 0.075→0.15; the detail text carries the real granularity.
enum NarrationPrepareStatus {
    static func batch(for progress: NarrationPrepareProgress) -> (fraction: Double, message: String) {
        switch progress {
        case .downloadingModels(let f):
            let c = min(max(f, 0), 1)
            return (0.075 * c, "Preparing voice models (one-time, ~850 MB)… \(Int(c * 100))%")
        case .compilingModels(let done, let total):
            let frac = total > 0 ? Double(done) / Double(total) : 0
            return (0.075 + 0.075 * frac, "Compiling voice models… \(done) of \(total)")
        case .ready:
            return (0.15, "Voice models ready")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationPrepareStatusTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "EchoCore/Services/Narration/TTSEngine.swift" "EchoTests/NarrationPrepareStatusTests.swift"
git commit -m "feat(narration): add prepare(progress:) overload + batch-status mapping"
```

---

### Task 4: Persist compiled models in `KokoroPipeline`

**Files:**
- Modify: `ThirdParty/KokoroPipeline/Sources/KokoroPipeline/KokoroPipeline.swift`
- Test: `ThirdParty/KokoroPipeline/Tests/KokoroPipelineTests/CompiledModelCacheTests.swift` (create)

**Interfaces:**
- Produces:
  - `static func KokoroPipeline.ensureCompiledModel(name: String, cacheDir: URL?, compile: (URL) throws -> URL, package: URL) throws -> URL`
  - `KokoroPipeline.init(modelsDirectory:compiledModelsDirectory:buckets:linearWeights:linearBias:compileProgress:)` — two new params (`compiledModelsDirectory: URL? = nil`, `compileProgress: ((Int, Int) -> Void)? = nil`).

- [ ] **Step 1: Write the failing test**

Create `ThirdParty/KokoroPipeline/Tests/KokoroPipelineTests/CompiledModelCacheTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import KokoroPipeline

@Suite struct CompiledModelCacheTests {
    @Test func compilesOnceThenReusesCache() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let cache = tmp.appendingPathComponent("compiled", isDirectory: true)
        let package = tmp.appendingPathComponent("m.mlpackage")

        var compileCount = 0
        // Stub compile: emit a fresh fake .mlmodelc dir each call (mimics
        // MLModel.compileModel returning a new temp URL).
        let compile: (URL) throws -> URL = { _ in
            compileCount += 1
            let out = tmp.appendingPathComponent("\(UUID().uuidString).mlmodelc", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        }

        let first = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: cache, compile: compile, package: package)
        let second = try KokoroPipeline.ensureCompiledModel(
            name: "m", cacheDir: cache, compile: compile, package: package)

        #expect(compileCount == 1)  // second call is a cache hit
        #expect(first == second)
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("m.mlmodelc").path))
    }

    @Test func nilCacheDirAlwaysCompiles() throws {
        var n = 0
        let compile: (URL) throws -> URL = { _ in n += 1; return URL(fileURLWithPath: "/tmp/x\(n).mlmodelc") }
        _ = try KokoroPipeline.ensureCompiledModel(name: "m", cacheDir: nil, compile: compile, package: URL(fileURLWithPath: "/tmp/m.mlpackage"))
        _ = try KokoroPipeline.ensureCompiledModel(name: "m", cacheDir: nil, compile: compile, package: URL(fileURLWithPath: "/tmp/m.mlpackage"))
        #expect(n == 2)  // no cache → compile every call (current behavior preserved)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ThirdParty/KokoroPipeline && swift test --filter CompiledModelCacheTests`
Expected: FAIL — `type 'KokoroPipeline' has no member 'ensureCompiledModel'`.

- [ ] **Step 3: Add the cache helper**

In `KokoroPipeline.swift`, inside `public class KokoroPipeline`, add:

```swift
/// Returns a loadable `.mlmodelc` for `package`, compiling once and caching it
/// under `cacheDir` when provided so later launches skip the multi-minute
/// `MLModel.compileModel`. On a cache write/move failure it falls back to the
/// freshly-compiled (temp) URL, so a full or read-only disk can't break
/// synthesis. The `compile` step is injected so the cache decision is testable
/// without a real CoreML model.
static func ensureCompiledModel(
    name: String, cacheDir: URL?, compile: (URL) throws -> URL, package: URL
) throws -> URL {
    guard let cacheDir else { return try compile(package) }
    let fm = FileManager.default
    let cached = cacheDir.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
    if fm.fileExists(atPath: cached.path) { return cached }
    let compiled = try compile(package)
    do {
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
        try fm.moveItem(at: compiled, to: cached)
        return cached
    } catch {
        return compiled  // don't break narration on a cache write failure
    }
}
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `cd ThirdParty/KokoroPipeline && swift test --filter CompiledModelCacheTests`
Expected: PASS.

- [ ] **Step 5: Wire the helper + progress into `init`**

In `KokoroPipeline.swift`, change the `public init(...)` signature to:

```swift
public init(
    modelsDirectory: URL,
    compiledModelsDirectory: URL? = nil,
    buckets: [Int] = PipelineConstants.defaultBuckets,
    linearWeights: [Float],
    linearBias: Float,
    compileProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
) throws {
```

Immediately inside the init body (before the duration loop), add the shared loader + total:

```swift
let durationChoices = Self.discoverDurationChoices(modelsDirectory: modelsDirectory)
let fm = FileManager.default
func present(_ name: String) -> Bool {
    fm.fileExists(atPath: modelsDirectory.appendingPathComponent(name).path)
}
// Count every model that will actually load, so compileProgress has a stable denominator.
let total =
    durationChoices.count
    + buckets.compactMap { PipelineConstants.tFramesForBucket[$0] }.filter { present("kokoro_f0ntrain_t\($0).mlpackage") }.count
    + buckets.filter { present("kokoro_decoder_pre_\($0)s.mlpackage") }.count
    + buckets.filter { present("kokoro_decoder_har_post_\($0)s.mlpackage") }.count
var done = 0
func loadModel(package: URL, name: String, units: MLComputeUnits) throws -> MLModel {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = units
    let url = try Self.ensureCompiledModel(
        name: name, cacheDir: compiledModelsDirectory,
        compile: { try MLModel.compileModel(at: $0) }, package: package)
    let model = try MLModel(contentsOf: url, configuration: cfg)
    done += 1
    compileProgress?(done, total)
    return model
}
```

Then replace the four `MLModel(contentsOf: MLModel.compileModel(at: …), configuration: …)` loops so each uses `loadModel`:

```swift
// Duration
var durModels: [String: MLModel] = [:]
for choice in durationChoices {
    durModels[choice.cacheKey] = try loadModel(
        package: choice.packageURL, name: choice.cacheKey, units: .cpuAndGPU)
}
guard !durModels.isEmpty else { throw PipelineError.modelNotLoaded("duration") }
self.durationModels = durModels
self.durationChoices = durationChoices

// F0Ntrain
var f0Models: [Int: MLModel] = [:]
for sec in buckets {
    if let t = PipelineConstants.tFramesForBucket[sec] {
        let url = modelsDirectory.appendingPathComponent("kokoro_f0ntrain_t\(t).mlpackage")
        if fm.fileExists(atPath: url.path) {
            f0Models[t] = try loadModel(package: url, name: "kokoro_f0ntrain_t\(t)", units: .cpuAndGPU)
        }
    }
}
self.f0ntrainModels = f0Models

// DecoderPre
var decPreModels: [Int: MLModel] = [:]
for sec in buckets {
    let url = modelsDirectory.appendingPathComponent("kokoro_decoder_pre_\(sec)s.mlpackage")
    if fm.fileExists(atPath: url.path) {
        decPreModels[sec] = try loadModel(package: url, name: "kokoro_decoder_pre_\(sec)s", units: .cpuAndNeuralEngine)
    }
}
self.decoderPreModels = decPreModels

// Generator (HAR-post)
var genModels: [Int: MLModel] = [:]
for sec in buckets {
    let url = modelsDirectory.appendingPathComponent("kokoro_decoder_har_post_\(sec)s.mlpackage")
    if fm.fileExists(atPath: url.path) {
        genModels[sec] = try loadModel(package: url, name: "kokoro_decoder_har_post_\(sec)s", units: .cpuAndGPU)
    }
}
self.generatorModels = genModels
self.availableBuckets = Array(genModels.keys.sorted())
```

(Compute-unit choices per stage are unchanged: duration/f0/generator `.cpuAndGPU`, decoder-pre `.cpuAndNeuralEngine`.)

- [ ] **Step 6: Build the package + run its tests**

Run: `cd ThirdParty/KokoroPipeline && swift build && swift test --filter KokoroPipelineTests`
Expected: build succeeds; existing pipeline tests still pass (signature change is source-compatible via defaults).

- [ ] **Step 7: Commit**

```bash
git add "ThirdParty/KokoroPipeline/Sources/KokoroPipeline/KokoroPipeline.swift" "ThirdParty/KokoroPipeline/Tests/KokoroPipelineTests/CompiledModelCacheTests.swift"
git commit -m "perf(narration): cache compiled Kokoro .mlmodelc + report compile progress"
```

---

### Task 5: Wire download + compile progress in `KokoroFixedShapeEngine`

**Files:**
- Modify: `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift`

**Interfaces:**
- Consumes: `NarrationPrepareProgress` (Task 3); `NarrationModelStore.ensureModels(progress:)`; `KokoroPipeline(modelsDirectory:compiledModelsDirectory:…:compileProgress:)` (Task 4).
- Produces: `KokoroFixedShapeEngine.prepare(progress:)` (the real override) + `prepare()` delegating to it.

> Integration wiring against real CoreML — not unit-tested here (the existing `KokoroFixedShapeEngineTests` cover the pure `PipelineInputs.make`). Verified by build + the on-device run.

- [ ] **Step 1: Replace `prepare()` with the progress-reporting override**

In `KokoroFixedShapeEngine.swift`, replace the whole `func prepare() async throws { … }` method with:

```swift
func prepare() async throws { try await prepare(progress: { _ in }) }

func prepare(progress: @Sendable (NarrationPrepareProgress) -> Void) async throws {
    // Coalesce concurrent prepares onto a single download + compile.
    if let task = initializationTask {
        try await task.value
        return
    }
    let task = Task<Void, Error> { [logger] in
        // Download the pruned model set (was: progress discarded as `nil`).
        let dir = try await NarrationModelStore.shared.ensureModels(
            progress: { f in progress(.downloadingModels(fraction: f)) })
        // Persist the compiled .mlmodelc next to the packages so the multi-minute
        // CoreML compile happens once ever; renderVersion-keyed via the subdir.
        let compiledDir = dir.appendingPathComponent("compiled", isDirectory: true)
        let built = try KokoroPipeline(
            modelsDirectory: dir,
            compiledModelsDirectory: compiledDir,
            buckets: NarrationModelStore.keptBucketSeconds,
            linearWeights: NarrationModelStore.hnsfLinearWeights,
            linearBias: NarrationModelStore.hnsfLinearBias,
            compileProgress: { done, total in progress(.compilingModels(done: done, total: total)) })
        await self.setPipeline(built)
        progress(.ready)
        logger.info("Fixed-shape pipeline ready.")
    }
    initializationTask = task
    try await task.value
}
```

- [ ] **Step 2: Build both app targets**

Run: `make build-tests` (builds the iOS `Echo` scheme + tests)
Expected: `** TEST BUILD SUCCEEDED **`

Run: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64' -jobs 5 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the existing narration suites (no regressions)**

Run: `make test-only FILTER=EchoTests/KokoroFixedShapeEngineTests` and `make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add "EchoCore/Services/Narration/KokoroFixedShapeEngine.swift"
git commit -m "feat(narration): report download+compile progress and persist compiled models"
```

---

### Task 6: Surface prepare progress in the macOS batch stage

**Files:**
- Modify: `Echo macOS/Services/MacBatchProcessingService.swift`

**Interfaces:**
- Consumes: `service.tts.prepare(progress:)` (Tasks 3+5); `NarrationPrepareStatus.batch(for:)` (Task 3); the nested `@MainActor func progress(_:_:_:)` (existing, line ~206).

> macOS-target code — build-verified; the mapping it relies on is unit-tested in Task 3.

- [ ] **Step 1: Call prepare explicitly before the chapter loop**

In `MacBatchProcessingService.swift`, in the `.narrate` branch, locate `var service = makeService()` (just before the `for (n, chapter) in chapters.enumerated()` loop) and insert immediately after it:

```swift
// One-time engine prepare (download + compile the CoreML model set) BEFORE the
// chapter loop, reported as its own phase. Without this the UI sits on
// "Narrating chapter 1" for minutes while prepare runs lazily inside the first
// synthesize. The engine invokes the progress closure off the main actor, so
// hop back to update the @MainActor `progress`.
do {
    try await service.tts.prepare(progress: { p in
        Task { @MainActor in
            let s = NarrationPrepareStatus.batch(for: p)
            progress(.transcribing, s.fraction, s.message)
        }
    })
} catch is CancellationError {
    throw CancellationError()
}
// A non-cancellation prepare failure (e.g. model download) propagates to the
// runner, which marks this book .failed — same as any stage error.
```

- [ ] **Step 2: Rebase the chapter-loop fraction to stay monotonic**

In the same `.narrate` branch, in the `progress(.transcribing, …)` call inside the chapter loop, change the fraction from:

```swift
0.1 + 0.85 * Double(n) / Double(chapters.count),
```

to:

```swift
0.15 + 0.80 * Double(n) / Double(chapters.count),
```

(Prepare filled `0 → 0.15`; the loop now continues upward from there.)

- [ ] **Step 3: Build the macOS app**

Run: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64' -jobs 5 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/Services/MacBatchProcessingService.swift"
git commit -m "feat(narration): show one-time model prepare progress in the macOS queue"
```

---

### Task 7: Surface prepare progress in iOS Now Playing

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationState.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Test: `EchoTests/NarrationStateTests.swift`

**Interfaces:**
- Consumes: `NarrationPrepareProgress` (Task 3); `narrationTTS.prepare(progress:)` (Task 5).
- Produces: `NarrationState.Phase.preparingEngine`.

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/NarrationStateTests.swift` (inside the existing suite):

```swift
@MainActor
@Test func preparingEngineCountsAsRunning() {
    let s = NarrationState()
    s.update(phase: .preparingEngine, progress: 0.2, statusMessage: "Compiling…")
    #expect(s.phase == .preparingEngine)
    #expect(s.isRunning)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationStateTests`
Expected: FAIL — `type 'NarrationState.Phase' has no member 'preparingEngine'`.

- [ ] **Step 3: Add the phase**

In `EchoCore/Services/Narration/NarrationState.swift`, add the case to the `Phase` enum (after `idle`):

```swift
case preparingEngine  // one-time model download + CoreML compile
```

and include it in `isRunning`'s "running" branch:

```swift
case .preparingEngine, .preparingChapter, .renderingAhead: return true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationStateTests`
Expected: PASS.

- [ ] **Step 5: Report prepare progress on the iOS render path**

In `EchoCore/ViewModels/PlayerModel+Narration.swift`, replace the prepare call at line ~153 (`try await self.narrationTTS.prepare()`) with:

```swift
try await self.narrationTTS.prepare(progress: { [weak self] p in
    Task { @MainActor in
        guard let self else { return }
        switch p {
        case .downloadingModels(let f):
            self.narrationState.update(
                phase: .preparingEngine, progress: 0.5 * f,
                statusMessage: "Downloading voice models… \(Int(min(max(f, 0), 1) * 100))%")
        case .compilingModels(let done, let total):
            let frac = total > 0 ? Double(done) / Double(total) : 0
            self.narrationState.update(
                phase: .preparingEngine, progress: 0.5 + 0.5 * frac,
                statusMessage: "Compiling voice models… \(done) of \(total)")
        case .ready:
            self.narrationState.update(
                phase: .preparingEngine, progress: 1.0, statusMessage: "Voice models ready")
        }
    }
})
```

(Confirm the property name `narrationState` matches the surrounding file; if the model exposes it under a different name, use that. The build step catches a mismatch.)

- [ ] **Step 6: Build + run the suite**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationStateTests`
Expected: `** TEST BUILD SUCCEEDED **` then PASS.

- [ ] **Step 7: Commit**

```bash
git add "EchoCore/Services/Narration/NarrationState.swift" "EchoCore/ViewModels/PlayerModel+Narration.swift" "EchoTests/NarrationStateTests.swift"
git commit -m "feat(narration): show model prepare progress in iOS Now Playing"
```

---

## Self-Review

**Spec coverage:**
- Workstream A (feedback): Tasks 3 (types + mapping + protocol), 5 (engine wiring), 6 (macOS surface), 7 (iOS surface). ✓
- Workstream B (persist compiled models): Task 4 (cache helper + init), consumed by Task 5. ✓
- Workstream C (queued-item removal): Tasks 1 (DAO) + 2 (UI). ✓
- Monotonic progress (prepare 0→0.15, loop 0.15+0.80): Task 3 mapping + Task 6 rebase. ✓
- Non-destructive removal: Task 1 status-guarded delete, no track/anchor writes. ✓
- Backward-compat overload: Task 3 extension default. ✓
- renderVersion-keyed cache: Task 5 passes `dir/compiled` under the versioned subdir. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. The one "confirm the property name" note in Task 7 Step 5 is a build-checked guard, not a placeholder (the surrounding file is named, the build verifies the symbol).

**Type consistency:** `NarrationPrepareProgress` cases (`downloadingModels(fraction:)`, `compilingModels(done:total:)`, `ready`) are used identically in Tasks 3, 5, 6, 7. `NarrationPrepareStatus.batch(for:)` returns `(fraction, message)` consumed in Task 6. `ensureCompiledModel(name:cacheDir:compile:package:)` defined in Task 4, called in the same task's init. `deleteQueued(id:)` defined in Task 1, called by `removeQueued` in Task 2. Consistent.

## Out-of-session verification (owner-driven)

After the plan lands, on the M1 Pro: first narration run shows "Downloading… %" → "Compiling… N of 20" → accurate "Narrating chapter N of M"; a **second** launch of the same book is fast (compiled-cache hit); a queued EPUB can be removed before it starts.
