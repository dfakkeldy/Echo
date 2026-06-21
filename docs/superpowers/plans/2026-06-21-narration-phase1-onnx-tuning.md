# Narration Phase 1: ONNX tuning + live progress — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover modest narration throughput on the A14 by tuning the ONNX Runtime session, and stop a long render from reading as a hang by mirroring per-block progress to the lock screen.

**Architecture:** `OnnxKokoroEngine` builds its `ORTSession` with bare options today; add graph-optimization + an injectable intra-op thread count (behavior-preserving — identical waveform, so `renderVersion` is untouched). Separately, `PlayerModel` reflects the already-per-block-updated `narrationPlaybackState` into the Now Playing / lock-screen subtitle during chapter preparation.

**Tech Stack:** Swift, ONNX Runtime ObjC bindings (`OnnxRuntimeBindings`), Swift Testing, GRDB (unaffected).

**Design spec:** `docs/superpowers/specs/2026-06-21-narration-streaming-and-onnx-tuning-design.md` §4.

## Global Constraints

- Branch off and PR into **`nightly`** (promotion ladder; never target `main`).
- iOS 18 / macOS 15 floors; engine code is `#if os(iOS) || os(macOS)`.
- Behavior-preserving: the rendered waveform must not change → `NarrationFileNaming.renderVersion` stays **6**.
- 16 GB machine: never run `xcodebuild` with parallel testing or two invocations concurrently. Use `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`.
- Conventional Commits; commit message footer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: Injectable ONNX session config (graph-opt + intra-op threads)

**Files:**
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift` (the two `init`s ~47-55; the `ORTSessionOptions` build ~104)
- Test: `EchoTests/OnnxKokoroEnginePrepareTests.swift` (extend existing suite)

**Interfaces:**
- Consumes: existing `OnnxKokoroEngine(modelProvider:)` test seam.
- Produces: `OnnxKokoroEngine(intraOpThreads: Int32 = 2)` and `OnnxKokoroEngine(modelProvider:intraOpThreads:)`; the engine applies `setGraphOptimizationLevel(.all)` and `setIntraOpNumThreads(intraOpThreads)` to its `ORTSessionOptions` during `prepare`.

- [ ] **Step 1: Write the failing test** — assert the engine retains an injected thread count (constructor seam), and that the default is 2.

In `EchoTests/OnnxKokoroEnginePrepareTests.swift`, add to the suite:

```swift
@Test func intraOpThreadsDefaultsToTwoAndIsInjectable() async {
    let def = OnnxKokoroEngine()
    #expect(await def.intraOpThreadsForTesting == 2)

    let custom = OnnxKokoroEngine(modelProvider: { _ in
        throw NarrationError.engineUnavailable
    }, intraOpThreads: 4)
    #expect(await custom.intraOpThreadsForTesting == 4)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/OnnxKokoroEnginePrepareTests`
Expected: FAIL to compile — `intraOpThreads:` argument and `intraOpThreadsForTesting` don't exist yet.

- [ ] **Step 3: Add the stored config + constructors + apply options**

In `OnnxKokoroEngine.swift`, add a stored property and thread the parameter through both inits:

```swift
/// Intra-op thread count for the CPU EP. The A14 has 2 performance cores;
/// pinning intra-op parallelism to them is the throughput lever measured on
/// device. Injectable so the on-device spike can compare 1/2/4.
private let intraOpThreads: Int32

/// Test seam: surface the configured thread count without exposing internals.
var intraOpThreadsForTesting: Int32 { intraOpThreads }

init(intraOpThreads: Int32 = 2) {
    self.modelProvider = { progress in try await Self.ensureModel(progress: progress) }
    self.intraOpThreads = intraOpThreads
}

init(
    modelProvider: @escaping @Sendable (@Sendable (Double) -> Void) async throws -> URL,
    intraOpThreads: Int32 = 2
) {
    self.modelProvider = modelProvider
    self.intraOpThreads = intraOpThreads
}
```

Then, where the session options are built inside the init `Task` (currently `let options = try ORTSessionOptions()`), apply the tuning. `intraOpThreads` is captured into the `Task` (add it to the capture list alongside `logger, modelProvider`):

```swift
let task = Task<Void, Error> { [logger, modelProvider, intraOpThreads] in
    defer { fan.clear() }
    let modelURL = try await modelProvider { f in
        fan.emit(.downloadingModels(fraction: f))
    }
    fan.emit(.compilingModels(done: 0, total: 1))
    let loadStart = Date()
    let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
    let options = try ORTSessionOptions()
    // Tuning (behavior-preserving): op fusion + pin intra-op parallelism to the
    // A14 performance cores. CPU EP only — no ANE (the A14 trap path).
    try options.setGraphOptimizationLevel(.all)
    try options.setIntraOpNumThreads(intraOpThreads)
    let session = try ORTSession(
        env: env, modelPath: modelURL.path, sessionOptions: options)
    // …unchanged below…
    let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
    logger.notice(
        "ONNX session created in \(loadMs, privacy: .public) ms (no AOT compile), intraOp=\(intraOpThreads, privacy: .public).")
    await self.store(env: env, session: session)
    fan.emit(.compilingModels(done: 1, total: 1))
    fan.emit(.ready)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-only FILTER=EchoTests/OnnxKokoroEnginePrepareTests`
Expected: PASS (both the new test and the existing `failedPrepareIsNotCachedSoTheNextCallRetries`).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/OnnxKokoroEngine.swift EchoTests/OnnxKokoroEnginePrepareTests.swift
git commit -m "perf(narration): tune ONNX session (graph-opt + injectable intra-op threads)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: On-device RTF measurement (manual, not a unit test)**

Run the app on the iPhone 12 Pro, narrate a chapter, and read the Console `OnnxKokoro` lines:
- `ONNX session created in N ms … intraOp=2` (confirms the option applied).
- per-synth `RTF …` lines.
Compare the steady-state RTF against the pre-change baseline (~0.5 cold → ~0.85 hot). Try `intraOpThreads` 1/2/4 by temporarily constructing the engine with each (the seam exists) and keep the best. If no value beats the default meaningfully, leave it at 2 — the change is still free (graph-opt) and harmless.

---

### Task 2: Mirror per-block progress to the lock screen

**Files:**
- Create: `EchoCore/Services/Narration/NarrationProgressText.swift`
- Test: `EchoTests/NarrationProgressTextTests.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift` (the render loop ~196-265, where each chapter is rendered)

**Interfaces:**
- Consumes: `NarrationState` (`narrationPlaybackState`) `phase`/`progress`/`currentChapterIndex`.
- Produces: `NarrationProgressText.subtitle(chapterDisplayNumber:fraction:) -> String`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NarrationProgressTextTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationProgressTextTests {
    @Test func formatsChapterAndPercent() {
        #expect(NarrationProgressText.subtitle(chapterDisplayNumber: 1, fraction: 0.0)
            == "Preparing chapter 1…")
        #expect(NarrationProgressText.subtitle(chapterDisplayNumber: 1, fraction: 0.4)
            == "Preparing chapter 1… 40%")
        #expect(NarrationProgressText.subtitle(chapterDisplayNumber: 3, fraction: 1.0)
            == "Preparing chapter 3… 100%")
    }

    @Test func clampsOutOfRangeFraction() {
        #expect(NarrationProgressText.subtitle(chapterDisplayNumber: 2, fraction: -0.5)
            == "Preparing chapter 2…")
        #expect(NarrationProgressText.subtitle(chapterDisplayNumber: 2, fraction: 1.5)
            == "Preparing chapter 2… 100%")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationProgressTextTests`
Expected: FAIL to compile — `NarrationProgressText` undefined.

- [ ] **Step 3: Write the pure formatter**

Create `EchoCore/Services/Narration/NarrationProgressText.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure formatting of narration prepare progress into a lock-screen subtitle, so
/// a multi-minute chapter-0 render reads as motion rather than a frozen "Preparing
/// narration…". At fraction 0 the percent is omitted (we haven't synthesized a
/// block yet); above 0 it appends a clamped whole-percent.
enum NarrationProgressText {
    static func subtitle(chapterDisplayNumber: Int, fraction: Double) -> String {
        let base = "Preparing chapter \(chapterDisplayNumber)…"
        guard fraction > 0 else { return base }
        let pct = Int((min(max(fraction, 0), 1) * 100).rounded())
        return "\(base) \(pct)%"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-only FILTER=EchoTests/NarrationProgressTextTests`
Expected: PASS.

- [ ] **Step 5: Wire it into the lock-screen subtitle during render**

In `PlayerModel+Narration.swift`, inside the chapter render loop (the `for (offset, chapter) in chapters.enumerated()` block, around the `service.renderChapter(...)` call ~234), reflect the live `narrationPlaybackState` into the Now Playing subtitle. Add, immediately before `try await service.renderChapter(...)`:

```swift
// Lock screen: name the chapter being prepared (the in-app NarrationStatusView
// already shows the per-block bar; the lock screen otherwise sits on the stale
// "Preparing narration…"). The per-block percent is refreshed in the cover
// callback below.
self.state.currentSubtitle = NarrationProgressText.subtitle(
    chapterDisplayNumber: chapter.displayNumber, fraction: 0)
self.progressPresenter.updateNowPlayingInfo(isPaused: true)
```

And pass a per-block progress callback into the service so the lock screen advances. Modify `NarrationService.renderChapter` to accept an optional callback and invoke it where it already updates `state` (NarrationService.swift:162-165). Add the parameter:

```swift
func renderChapter(
    chapterIndex: Int, chapterNumber: Int? = nil,
    blocks: [EPubBlockRecord], voice: VoiceID,
    onBlockProgress: (@MainActor (_ chapterDisplayNumber: Int, _ fraction: Double) -> Void)? = nil
) async throws {
```

Inside the per-block update (right after the existing `state.update(... progress: Double(i + 1) / Double(spoken.count) ...)`), add:

```swift
onBlockProgress?(displayNumber, Double(i + 1) / Double(spoken.count))
```

Then at the call site in `PlayerModel+Narration.swift`, pass:

```swift
try await service.renderChapter(
    chapterIndex: chapter.index, chapterNumber: chapter.displayNumber,
    blocks: chapter.blocks, voice: voice.id,
    onBlockProgress: { [weak self] displayNumber, fraction in
        guard let self else { return }
        self.state.currentSubtitle = NarrationProgressText.subtitle(
            chapterDisplayNumber: displayNumber, fraction: fraction)
        self.progressPresenter.updateNowPlayingInfo(isPaused: true)
    })
```

(The `onBlockProgress` default is `nil`, so the existing tests and the macOS batch caller compile unchanged.)

- [ ] **Step 6: Build the iOS + macOS targets**

Run: `make build-tests`
Expected: BUILD SUCCEEDED (the new optional parameter is source-compatible; macOS `renderChapter` callers pass no callback).

- [ ] **Step 7: Run the narration test suites to confirm no regression**

Run: `make test-only FILTER=EchoTests/NarrationProgressTextTests` then `make test-only FILTER=EchoTests/NarrationServiceTests`
Expected: PASS (and any other `Narration*` suites the build surfaces).

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Services/Narration/NarrationProgressText.swift EchoTests/NarrationProgressTextTests.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "feat(narration): show per-block prepare progress on the lock screen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (already applied)

- **Spec coverage:** §4a (session options) → Task 1; §4b (live progress) → Task 2. ✅
- **Behavior-preserving:** no `renderVersion` change; waveform unchanged. ✅
- **Type consistency:** `intraOpThreads: Int32` matches the ObjC `setIntraOpNumThreads:(int)` selector; `NarrationProgressText.subtitle(chapterDisplayNumber:fraction:)` used identically in test and call site. ✅
- **Note:** Task 2 is largely subsumed once Phase 2 streaming lands (the cold-start wait disappears), but it ships value while Phase 2 is in flight and is cheap to keep.

## Verification before "done"

Run the full narration suite and confirm green, then PR into `nightly`:

```bash
make build-tests
make test-only FILTER=EchoTests/OnnxKokoroEnginePrepareTests
make test-only FILTER=EchoTests/NarrationProgressTextTests
```
