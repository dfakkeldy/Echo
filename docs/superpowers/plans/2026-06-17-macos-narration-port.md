# macOS On-Device Narration Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring on-device EPUB→audio narration (Kokoro via FluidAudio) to the macOS app and let the overnight batch queue synthesize text-only EPUBs, then play the result.

**Architecture:** The narration *engine* already lives in shared `EchoCore/` and compiles into the macOS target as `#if os(iOS)`-emptied shells. The port is **target-wiring + de-gating**, not new ML work: link FluidAudio to the macOS target, de-gate `KokoroTTSEngine`, relocate the one iOS-coupled helper (`narrationCacheDirectory`), add a `synthesize` stage + a narrate-kind to the existing batch queue, bridge the macOS player's track *discovery* to read `TrackRecord` rows (the real structural gap), and port the 3 narration UI views. Five phases, P0 first to retire the only runtime unknown.

**Tech Stack:** Swift 6, SwiftUI/AppKit, AVFoundation, GRDB, FluidAudio (Kokoro-82M CoreML, ANE), CoreML. macOS deployment target is **15.0** (clears FluidAudio's `.macOS(.v14)` floor).

---

## What this builds on (read before starting)

- The **karaoke/batch branch is merged to `main`** (`afbdfcd`). The persistent macOS batch queue exists: `Shared/BatchQueueRunner.swift` (FIFO drain + failure isolation + restart recovery), `Echo macOS/Services/MacBatchProcessingService.swift` (import→transcribe→align stages behind `BatchQueueRunner.Stages.run`), `Echo macOS/Services/FolderAudioScanner.swift` (folder scan → enqueue), `batch_queue` table (`Schema_V20`), `BatchQueueRecord`/`BatchQueueDAO`.
- **Feasibility was scoped (2026-06-17, read-only investigation).** Critical path is GREEN: FluidAudio's `Package.swift` declares `.macOS(.v14)`, ships a macOS CLI, uses no UIKit; the iOS-only status is purely Echo wiring. `NarrationCapability.supportsOnDeviceNarration` already returns true for Macs. The A14 ANE trap does **not** apply to M-series (FluidAudio 0.15.4's default `ane-tail-gpu` routing runs on every Apple Silicon generation) — no model swap needed.
- **Locked product decisions:**
  1. **Model delivery = runtime download** — FluidAudio fetches Kokoro from HuggingFace into the sandbox cache on first synthesis (zero Echo code, matches iOS).
  2. **v1 scope = playback only; m4b export DEFERRED** — `ChapterMarkerWriter`/`swift-audio-marker` on macOS is unverified; out of scope here (see "Deferred").
  3. **Enqueue UX = a dedicated "Narrate EPUB(s)…" command** — distinct from "Add Folder to Queue" (audiobook alignment).
  4. **No Mac SoC gate** — keep the A15+ branch iPhone-only; Macs are "supported" as today.
  5. **One `synthesize` stage inside the existing queue** — not a separate narration queue.

### Verified current seams (don't reinvent)

```swift
// EchoCore/Services/Narration/TTSEngine.swift
protocol TTSEngine: Sendable {
    func prepare() async throws
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
}
struct TTSChunk: Sendable, Equatable { let samples: [Float]; let sampleRate: Double; let duration: TimeInterval; static func silence(seconds:sampleRate:) -> TTSChunk }
struct VoiceID: RawRepresentable, Hashable, Sendable, Codable { ... }

// EchoCore/Services/Narration/KokoroTTSEngine.swift  — the ONLY concrete engine, currently #if os(iOS)
#if os(iOS)
import FluidAudio
actor KokoroTTSEngine: TTSEngine { /* uses KokoroAneManager(); synthesizeDetailed(text:voice:) */ }
#endif

// EchoCore/Services/Narration/NarrationService.swift:65  — already portable (no UIKit), @MainActor @Observable
func renderChapter(chapterIndex: Int, chapterNumber: Int? = nil, blocks: [EPubBlockRecord], voice: VoiceID) async throws
//   writes one ALAC .m4a per chapter into `cacheDirectory` + one .synthesized AlignmentAnchorRecord per block + a TrackRecord row

// EchoCore/ViewModels/PlayerModel+Narration.swift:291  — iOS-only static; MUST be relocated to be macOS-callable
static func narrationCacheDirectory() -> URL   // Application Support/Narration, excluded from backup

// EchoCore/Services/Narration/NarrationCapability.swift:19
static var supportsOnDeviceNarration: Bool     // A15+ on iPhone; true for Macs already

// Shared/BatchQueueRunner.swift:10  — the stage seam (generic drain loop, unchanged)
struct Stages { let run: (BatchQueueRecord, _ progress: @MainActor (BatchItemStatus, Double, String?) -> Void) async throws -> Void }

// Echo macOS/Views/MacPlayerModel.swift:392  — the playback DISCOVERY gap
func loadFolder(url folderURL: URL)   // discovers tracks by FILESYSTEM scan; never reads TrackRecord rows
```

---

## File Structure Map

| File | Phase | Create/Modify | Role |
|------|-------|---------------|------|
| `Echo.xcodeproj/project.pbxproj` | P0 | Modify | Link `FluidAudio` product to the **Echo macOS** target |
| `EchoCore/Services/Narration/KokoroTTSEngine.swift` | P0 | Modify | De-gate `#if os(iOS)` → also macOS |
| `Echo macOS/Views/MacNarrationSpike.swift` | P0 | Create (temp, DEBUG) | One-shot on-device synth spike; deleted in P1 |
| `EchoCore/Services/Narration/NarrationCache.swift` | P1 | Create | Relocated, shared `narrationCacheDirectory()` |
| `EchoCore/ViewModels/PlayerModel+Narration.swift` | P1 | Modify | Call the shared cache helper (iOS path unchanged) |
| `EchoCore/Views/ExportProgressView.swift`, `NowPlayingTab.swift` | P1 | Modify | Update cache-dir call sites |
| `EchoCore/Services/Narration/NarrationEngineFactory.swift` | P1 | Create | Cross-platform `TTSEngine` provider (real vs mock) |
| `Shared/Database/Migrations/Schema_V21.swift` | P2 | Create | `batch_queue.kind` column (align/narrate) |
| `Shared/Database/BatchQueueRecord.swift` | P2 | Modify | Add `kind: BatchItemKind` |
| `Shared/Database/DatabaseService.swift` | P2 | Modify | Register V21 |
| `Echo macOS/Services/FolderAudioScanner.swift` | P2 | Modify | EPUB-only scan + narrate-enqueue |
| `Echo macOS/Services/MacBatchProcessingService.swift` | P2 | Modify | `synthesize` stage for narrate items |
| `Echo macOS/Echo_macOSApp.swift` | P2 | Modify | "Narrate EPUB(s)…" command |
| `Echo macOS/Services/MacNarrationTrackLoader.swift` | P3 | Create | Pure: `TrackRecord` rows → ordered `[URL]` |
| `Echo macOS/Views/MacPlayerModel.swift` | P3 | Modify | `loadNarratedBook(audiobookID:)` — DB-driven track discovery |
| `Echo macOS/Views/MacBatchQueueView.swift` / `MacTriPaneView.swift` | P3 | Modify | Open a completed narrated book |
| `Echo.xcodeproj/project.pbxproj` | P4 | Modify | Un-exclude the 3 narration views from macOS |
| `EchoCore/Views/Narration/VoicePickerView.swift`, `NarrationNudgeView.swift` | P4 | Modify | Replace iOS-only SwiftUI modifiers |
| `Echo macOS/Views/MacSettingsView.swift` / `MacPlayerMoreMenu.swift` | P4 | Modify | macOS narration entry points |

---

## Phase P0 — De-risk spike: one chapter synthesizes on a real Mac

> **Outcome:** prove FluidAudio/Kokoro runs on the user's Apple Silicon Mac before any further investment. This phase ends with a **manual on-device run** — the one thing no automated step can prove.

### Task P0.1: Link FluidAudio to the Echo macOS target

**Files:** Modify `Echo.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the FluidAudio product to the macOS target**

In Xcode (preferred): select the **Echo macOS** target → General → Frameworks, Libraries, and Embedded Content → **+** → add **FluidAudio** (already resolved for the iOS target). No new package needed — it's the same `https://github.com/FluidInference/FluidAudio.git` pin already in `Package.resolved`.

> **CLI alternative (no GUI):** in `project.pbxproj`, add an `XCSwiftPackageProductDependency` for `FluidAudio` to the Echo macOS target's `packageProductDependencies` and a corresponding `productRef` in that target's Frameworks `PBXBuildFile`/build phase. Mirror exactly how the **iOS** target references FluidAudio. The scope located the iOS product list near `project.pbxproj:350-355` and the macOS Frameworks phase id `AA0100000000000000000030` (currently WhisperKit-only) — **verify these against the current file before editing** (the file changed when swift-audio-marker was added). If you can't add it cleanly, report BLOCKED rather than leave a corrupted project.

- [ ] **Step 2: Resolve + confirm**

Run: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -resolvePackageDependencies 2>&1 | tail -5`
Expected: resolves with no error; FluidAudio now available to the macOS target.

- [ ] **Step 3: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build(macos): link FluidAudio to the Echo macOS target"
```

### Task P0.2: De-gate `KokoroTTSEngine` for macOS

**Files:** Modify `EchoCore/Services/Narration/KokoroTTSEngine.swift`

- [ ] **Step 1: Widen the platform gates**

The file has two `#if os(iOS)` gates: the `import FluidAudio` (lines ~3–5) and the whole `actor KokoroTTSEngine: TTSEngine { … }` (line ~9 to the closing `#endif`). Change **both** to include macOS:

```swift
#if os(iOS) || os(macOS)
import FluidAudio
#endif
```
```swift
#if os(iOS) || os(macOS)
actor KokoroTTSEngine: TTSEngine { /* unchanged body */ }
#endif
```

> The body needs no change — `KokoroAneManager()`, `manager.initialize()`, `manager.synthesizeDetailed(text:voice:)`, and `TTSChunk` are all platform-neutral per the scope. The `logger.debug("\(summary, privacy: .public)")` interpolation compiles on both.

- [ ] **Step 2: Build the macOS target**

Run: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: **BUILD SUCCEEDED** (KokoroTTSEngine now compiles into macOS). Fix any FluidAudio API mismatch by reading the resolved package's headers.

- [ ] **Step 3: iOS regression build**

Run: `make build-tests`
Expected: iOS still compiles (the widened gate is a superset; the iOS path is unchanged).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/KokoroTTSEngine.swift
git commit -m "feat(macos): de-gate KokoroTTSEngine so the Kokoro engine builds on macOS"
```

### Task P0.3: Manual on-device synthesis spike (acceptance gate)

**Files:** Create `Echo macOS/Views/MacNarrationSpike.swift` (temporary, `#if DEBUG`)

- [ ] **Step 1: Add a DEBUG-only spike command**

Add a minimal, DEBUG-gated macOS menu command that drives one chapter through the real engine against the currently-loaded (or a hardcoded test) EPUB's blocks. It must touch nothing in the shipping flow.

```swift
// Echo macOS/Views/MacNarrationSpike.swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import GRDB

/// TEMPORARY P0 spike — deleted in P1. Proves on-device Kokoro synthesis on macOS.
enum MacNarrationSpike {
    /// Renders chapter 0 of `audiobookID` to the narration cache via the real engine.
    @MainActor
    static func run(audiobookID: String, dbService: DatabaseService) async {
        do {
            let blocks = try dbService.writer.read { db in
                try EPubBlockRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .order(Column("sequence_index"))
                    .fetchAll(db)
            }
            let service = NarrationService(
                audiobookID: audiobookID,
                writer: dbService.writer,
                engine: KokoroTTSEngine(),
                audioWriter: AVFoundationAudioWriter(),
                cacheDirectory: PlayerModel.narrationCacheDirectory())  // P1 relocates this
            try await service.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceCatalog.default.id)
            print("[SPIKE] rendered chapter 0 OK")
        } catch {
            print("[SPIKE] FAILED: \(error)")
        }
    }
}
#endif
```

> **Read first:** confirm the exact `NarrationService.init` signature and `VoiceCatalog.default` (the `VoiceID`) before writing this — adjust the call to match. `PlayerModel.narrationCacheDirectory()` is iOS-only until P1; for the spike, inline `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Narration")` if the iOS static isn't visible from the macOS target.

- [ ] **Step 2: Wire a temporary menu item** in `Echo_macOSApp.swift` under `#if DEBUG` that calls `MacNarrationSpike.run(...)` for the open book.

- [ ] **Step 3: MANUAL on-device run (the gate)**

Build + run the Echo macOS app on the **physical Apple Silicon Mac**. Open/seed a book that has `epub_block` rows, trigger the spike command. **Acceptance:** FluidAudio downloads the Kokoro model into the sandbox cache, synthesis produces audio, and an ALAC `.m4a` + a `TrackRecord` row + per-block `.synthesized` anchors land on disk — with **no** BNNS/ANE crash. Capture the console summary (`Synthesized … RTF …`).

> This is the one step automation cannot perform. If it crashes or the model download fails under the sandbox, STOP — that is a real blocker to surface (the `network.client` entitlement is present and the cache lands in-container, so download is expected to work).

- [ ] **Step 4: Commit the spike** (kept until P1 replaces it)

```bash
git add "Echo macOS/Views/MacNarrationSpike.swift" "Echo macOS/Echo_macOSApp.swift"
git commit -m "spike(macos): DEBUG one-chapter narration synthesis harness [temporary]"
```

---

## Phase P1 — Engine port behind the seam + relocate the cache helper

> **Prerequisite:** P0 green on hardware.

### Task P1.1: Relocate `narrationCacheDirectory()` to a shared type

**Files:** Create `EchoCore/Services/Narration/NarrationCache.swift`; modify `PlayerModel+Narration.swift`, `ExportProgressView.swift`, `NowPlayingTab.swift`; Test `EchoTests/NarrationCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/NarrationCacheTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct NarrationCacheTests {
    @Test func directoryIsUnderApplicationSupportNarration() throws {
        let dir = NarrationCache.directory()
        #expect(dir.lastPathComponent == "Narration")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL (`NarrationCache` undefined).

- [ ] **Step 3: Create `NarrationCache`** by moving the body of `PlayerModel.narrationCacheDirectory()` (`PlayerModel+Narration.swift:291`) verbatim into a platform-neutral type:

```swift
// EchoCore/Services/Narration/NarrationCache.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where rendered narration audio lives, shared by iOS + macOS. Application
/// Support/Narration, excluded from backup. (Relocated from the iOS-only
/// PlayerModel+Narration extension so the macOS batch can write to the same place.)
enum NarrationCache {
    static func directory() -> URL {
        // … exact body moved from PlayerModel.narrationCacheDirectory():291-302 …
    }
}
```

- [ ] **Step 4: Repoint iOS call sites** — `PlayerModel.narrationCacheDirectory()` becomes a thin `NarrationCache.directory()` forwarder (keep the symbol so existing iOS call sites in `ExportProgressView.swift:20` and `NowPlayingTab.swift:190` keep compiling), or update those two call sites to `NarrationCache.directory()`. Verify the iOS backup-exclusion behavior is unchanged.

- [ ] **Step 5: Run tests + iOS build**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationCacheTests`
Expected: PASS; iOS narration cache path unchanged.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/NarrationCache.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/Views/ExportProgressView.swift EchoCore/Views/NowPlayingTab.swift EchoTests/NarrationCacheTests.swift
git commit -m "refactor(narration): relocate narration cache dir to shared NarrationCache"
```

### Task P1.2: Cross-platform engine factory + delete the spike

**Files:** Create `EchoCore/Services/Narration/NarrationEngineFactory.swift`; delete `Echo macOS/Views/MacNarrationSpike.swift`

- [ ] **Step 1: Provide the engine behind the seam**

```swift
// EchoCore/Services/Narration/NarrationEngineFactory.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Supplies the concrete `TTSEngine` for real synthesis (iOS + macOS), or a mock in tests.
enum NarrationEngineFactory {
    static func make() -> TTSEngine {
        #if os(iOS) || os(macOS)
        return KokoroTTSEngine()
        #else
        return MockTTSEngine()   // unsupported platforms
        #endif
    }
}
```

- [ ] **Step 2: Confirm `NarrationCapability` keeps Macs supported** — read `NarrationCapability.swift:19`; ensure no change makes Macs fall through the A15+ iPhone branch. (No edit expected; add a test asserting `supportsOnDeviceNarration == true` on macOS if cheaply expressible.)

- [ ] **Step 3: Remove the temporary spike**

```bash
git rm "Echo macOS/Views/MacNarrationSpike.swift"
```
Remove the DEBUG menu item from `Echo_macOSApp.swift`.

- [ ] **Step 4: Build both targets + commit**

```bash
make build-tests
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
git add EchoCore/Services/Narration/NarrationEngineFactory.swift "Echo macOS/Echo_macOSApp.swift"
git rm "Echo macOS/Views/MacNarrationSpike.swift"
git commit -m "feat(narration): cross-platform TTSEngine factory; remove P0 spike"
```

---

## Phase P2 — Batch synthesize stage + EPUB-only enqueue + "Narrate EPUB(s)…"

> **Prerequisite:** P1. `batch_queue` (V20) is **already shipped on `main`**, so the kind column needs a **new** migration `Schema_V21` (do NOT edit V20).

### Task P2.1: `batch_queue.kind` column (Schema V21)

**Files:** Create `Shared/Database/Migrations/Schema_V21.swift`; modify `Shared/Database/BatchQueueRecord.swift`, `Shared/Database/DatabaseService.swift`; Test `EchoTests/BatchQueueDAOTests.swift` (extend)

- [ ] **Step 1: Write the failing test** (extend `BatchQueueDAOTests`)

```swift
@Test func defaultsToAlignKindAndRoundTripsNarrate() throws {
    let db = try DatabaseService(inMemory: ())
    let dao = BatchQueueDAO(db: db.writer)
    let item = try dao.enqueue(BatchQueueRecord(
        audiobookID: "bk", sourceBookmark: Data(), companionBookmark: nil,
        displayName: "B", queuePosition: 0, status: .queued, progress: 0,
        kind: .narrate, enqueuedAt: "2026-06-17T00:00:00Z"))
    #expect(try dao.allItems().first(where: { $0.id == item.id })?.kind == .narrate)
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL (`kind` / `BatchItemKind` undefined).

- [ ] **Step 3: Add `BatchItemKind` + the column**

```swift
// In BatchQueueRecord.swift:
enum BatchItemKind: String, Codable { case align, narrate }
// add stored property:
var kind: BatchItemKind = .align
// add to CodingKeys: case kind
```

```swift
// Shared/Database/Migrations/Schema_V21.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
/// V21 — batch_queue.kind discriminates audiobook-alignment items from
/// text-only EPUB narration items.
enum Schema_V21 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "batch_queue") { t in
            t.add(column: "kind", .text).notNull().defaults(to: "align")
        }
    }
}
```

Register in `DatabaseService.runMigrations` after V20:
```swift
        migrator.registerMigration("v21_batch_kind") { db in try Schema_V21.migrate(db) }
```

- [ ] **Step 4: Run tests** — `make test-only FILTER=EchoTests/BatchQueueDAOTests` → PASS.

- [ ] **Step 5: Schema review + commit** — run the `schema-migration-reviewer` agent (additive `ALTER ADD` with default — safe). Then:

```bash
git add Shared/Database/Migrations/Schema_V21.swift Shared/Database/BatchQueueRecord.swift Shared/Database/DatabaseService.swift Shared/Database/DAOs/BatchQueueDAO.swift EchoTests/BatchQueueDAOTests.swift
git commit -m "feat(db): add batch_queue.kind (align/narrate) — Schema V21"
```

### Task P2.2: EPUB-only scan + narrate-enqueue

**Files:** Modify `Echo macOS/Services/FolderAudioScanner.swift`, `Echo macOS/Services/MacBatchProcessingService.swift`

- [ ] **Step 1: Add an EPUB scanner + a narrate enqueue path**

In `FolderAudioScanner`, add `scanForEPUBs(in:) -> [URL]` (mirror `scanForAudioFiles`, extension `epub`) and an `enqueueEPUBsForNarration(_ folderURL:into:)` that bookmarks **the EPUB itself** as the primary `sourceBookmark` (no audio companion) and enqueues with `kind: .narrate`.

```swift
@MainActor
static func enqueueEPUBsForNarration(_ folderURL: URL, into service: MacBatchProcessingService) throws {
    let didStart = folderURL.startAccessingSecurityScopedResource()
    defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
    for epubURL in scanForEPUBs(in: folderURL) {
        try service.enqueueNarration(epubURL: epubURL)
    }
}
```

- [ ] **Step 2: Add `MacBatchProcessingService.enqueueNarration(epubURL:)`** mirroring `enqueue(fileURL:companionEPUB:)` (`MacBatchProcessingService.swift:75`) but: the EPUB is the bookmarked primary source, `kind = .narrate`, and `audiobookID` derives from the EPUB's parent dir `absoluteString` (consistent with the existing device-local scheme — portability is a separately-tracked concern, not fixed here).

- [ ] **Step 3: Build macOS + commit**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
git add "Echo macOS/Services/FolderAudioScanner.swift" "Echo macOS/Services/MacBatchProcessingService.swift"
git commit -m "feat(batch-macos): enqueue standalone EPUBs as narrate items"
```

### Task P2.3: The `synthesize` stage

**Files:** Modify `Echo macOS/Services/MacBatchProcessingService.swift`

- [ ] **Step 1: Branch the stage on `kind`**

In `makeStages()` (`MacBatchProcessingService.swift:152`), branch the `run` closure: `kind == .align` keeps today's import→transcribe→align; `kind == .narrate` resolves the EPUB bookmark, imports its blocks (no audio), then loops `NarrationService.renderChapter` per chapter using `NarrationEngineFactory.make()` + `AVFoundationAudioWriter()` + `NarrationCache.directory()`. Report progress per chapter via the `progress` callback. A render throw marks the item `.failed` (the runner already isolates failures).

```swift
// inside run, for .narrate:
progress(.importing, 0.05, "Importing EPUB…")
try await self?.importEPUBOnly(epubURL: resolvedEPUB, audiobookID: audiobookID, dbService: dbService)
let blocks = /* fetch epub_block rows for audiobookID, ordered */
let chapters = NarrationChapterPlanner.plan(blocks)   // reuse the existing planner
let service = NarrationService(audiobookID: audiobookID, writer: dbService.writer,
                               engine: NarrationEngineFactory.make(),
                               audioWriter: AVFoundationAudioWriter(),
                               cacheDirectory: NarrationCache.directory())
for (n, chapter) in chapters.enumerated() {
    progress(.transcribing, 0.1 + 0.85 * Double(n) / Double(max(1, chapters.count)),
             "Narrating chapter \(n + 1) of \(chapters.count)…")
    try await service.renderChapter(chapterIndex: chapter.index, chapterNumber: n + 1,
                                    blocks: chapter.blocks, voice: VoiceCatalog.default.id)
}
```

> **Read first:** the real `NarrationChapterPlanner` API and `NarrationService.init` signature — adjust names to match. Reuse `importEPUB` logic from the align path for `importEPUBOnly` (it already persists `epub_block` rows from an EPUB; no audio needed).

- [ ] **Step 2: Build macOS + manual smoke** — build; then via the P2.4 command, enqueue one text-only EPUB and confirm it advances importing→narrating→completed with `.m4a` files + `TrackRecord` rows landing. Apply the `xcrun simctl shutdown all` retry only if a sim is involved (macOS build doesn't need it).

- [ ] **Step 3: Commit**

```bash
git add "Echo macOS/Services/MacBatchProcessingService.swift"
git commit -m "feat(batch-macos): synthesize stage narrates text-only EPUB queue items"
```

### Task P2.4: "Narrate EPUB(s)…" command

**Files:** Modify `Echo macOS/Echo_macOSApp.swift`

- [ ] **Step 1: Add the command** in the existing **Batch** `CommandMenu`, alongside "Add Folder to Queue…":

```swift
Button("Narrate EPUB(s)…") {
    if let folder = chooseEPUBFolder() {   // NSOpenPanel, canChooseDirectories + .epub files
        try? FolderAudioScanner.enqueueEPUBsForNarration(folder, into: batchService)
    }
}
.keyboardShortcut("n", modifiers: [.command, .option])
```

Add `chooseEPUBFolder()` mirroring `chooseBatchFolder()` but allowing `.epub` files (and/or a folder of them).

- [ ] **Step 2: Build macOS + commit**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
git add "Echo macOS/Echo_macOSApp.swift"
git commit -m "feat(macos): Narrate EPUB(s) command enqueues text-only EPUBs for synthesis"
```

---

## Phase P3 — Surface rendered tracks for macOS playback (REQUIRED)

> The structural gap: `MacPlayerModel.loadFolder` (`MacPlayerModel.swift:392`) discovers tracks by **filesystem scan** of a book folder; narration `.m4a` files live in `Application Support/Narration`, outside any folder, so synthesized audio is unplayable until the player reads `TrackRecord` rows. Codec is fine — AVPlayer decodes ALAC and `.m4a` is already supported.

### Task P3.1: Pure track loader (TrackRecord → ordered URLs)

**Files:** Create `Echo macOS/Services/MacNarrationTrackLoader.swift`; Test `EchoTests/MacNarrationTrackLoaderTests.swift` — **only if** the macOS-only type is visible to the iOS test target; otherwise keep the pure mapping in `Shared/` so it's testable (preferred).

- [ ] **Step 1: Put the pure mapping in `Shared/` and test it**

```swift
// Shared/NarrationTrackOrdering.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
/// Orders a book's TrackRecord rows into a playable URL list (sortOrder asc).
enum NarrationTrackOrdering {
    static func orderedFileURLs(_ tracks: [TrackRecord]) -> [URL] {
        tracks.filter { $0.isEnabled }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { URL(fileURLWithPath: $0.filePath) }
    }
}
```

```swift
// EchoTests/NarrationTrackOrderingTests.swift
@Test func ordersBySortOrderAndMapsFilePaths() {
    let t = [TrackRecord(id:"b", audiobookID:"x", title:"2", duration:1, filePath:"/b.m4a", isEnabled:true, sortOrder:1, playlistPosition:nil, narrationVoice:"ava"),
             TrackRecord(id:"a", audiobookID:"x", title:"1", duration:1, filePath:"/a.m4a", isEnabled:true, sortOrder:0, playlistPosition:nil, narrationVoice:"ava")]
    #expect(NarrationTrackOrdering.orderedFileURLs(t).map(\.lastPathComponent) == ["a.m4a", "b.m4a"])
}
```

> **Read first:** the exact `TrackRecord` initializer (field order/names) before writing the test fixture.

- [ ] **Step 2: Run** — `make test-only FILTER=EchoTests/NarrationTrackOrderingTests` → PASS.

### Task P3.2: `MacPlayerModel.loadNarratedBook(audiobookID:)`

**Files:** Modify `Echo macOS/Views/MacPlayerModel.swift`

- [ ] **Step 1: Add a DB-driven load path** that reads `TrackRecord` rows for the book via `TrackDAO`, maps them with `NarrationTrackOrdering.orderedFileURLs`, sets `tracks` + `currentTrackIndex = 0`, and calls `open(url:)` on the first — reusing the existing AVPlayer + periodic-time-observer pipeline (no AVAudioEngine needed). Mirror `loadFolder`'s structure but source URLs from the DB, not a folder scan. `folderURL` may be left nil or set to the cache dir.

- [ ] **Step 2: Build macOS + manual verify**

Build; open a completed narrated book (P3.3) and confirm it plays through chapters, the scrubber works, and chapter nav behaves. Manual (audio playback can't be unit-asserted).

- [ ] **Step 3: Commit**

```bash
git add "Echo macOS/Views/MacPlayerModel.swift" Shared/NarrationTrackOrdering.swift EchoTests/NarrationTrackOrderingTests.swift
git commit -m "feat(macos): play narrated books by loading TrackRecord rows from the DB"
```

### Task P3.3: Open a completed narrated book

**Files:** Modify `Echo macOS/Views/MacBatchQueueView.swift` (and/or `MacTriPaneView.swift`)

- [ ] **Step 1: Add an action** on a completed narrate item (and/or a library entry) that calls `player.loadNarratedBook(audiobookID:)`. Build macOS + commit.

```bash
git add "Echo macOS/Views/MacBatchQueueView.swift"
git commit -m "feat(macos): open a completed narrated book from the batch queue"
```

---

## Phase P4 — macOS narration UI

> **Prerequisite:** P3 (so the UI drives a usable feature).

### Task P4.1: Port the 3 narration views to macOS

**Files:** Modify `Echo.xcodeproj/project.pbxproj` (remove the 3 views from the macOS `membershipExceptions`); modify `EchoCore/Views/Narration/VoicePickerView.swift`, `NarrationNudgeView.swift`

- [ ] **Step 1: Un-exclude the views** — remove `VoicePickerView.swift`, `NarrationStatusView.swift`, `NarrationNudgeView.swift` from the Echo macOS target's `membershipExceptions` in `project.pbxproj`.

- [ ] **Step 2: Replace iOS-only SwiftUI**
  - `NarrationStatusView` — already cross-platform; no change.
  - `VoicePickerView.swift:36,49` — guard/replace `.navigationBarTitleDisplayMode(...)` and `.presentationDetents(...)` (iOS-only) with `#if os(iOS)` or macOS-appropriate equivalents.
  - `NarrationNudgeView.swift:34` — replace `Color(.secondarySystemBackground)` with a cross-platform color (e.g. `Color(nsColor: .windowBackgroundColor)` under `#if os(macOS)`).

- [ ] **Step 3: Build macOS** — `xcodebuild … -scheme "Echo macOS" … build` → BUILD SUCCEEDED. Commit.

```bash
git add Echo.xcodeproj/project.pbxproj EchoCore/Views/Narration/VoicePickerView.swift EchoCore/Views/Narration/NarrationNudgeView.swift
git commit -m "feat(macos): port narration UI views (voice picker, status, nudge)"
```

### Task P4.2: macOS narration entry points

**Files:** Modify `Echo macOS/Views/MacSettingsView.swift` and/or `MacPlayerMoreMenu.swift`

- [ ] **Step 1: Surface voice selection + status** — add a voice picker entry (Settings Playback pane or the More menu) bound to the shared voice setting, and show `NarrationStatusView` while a narrate item renders. Build macOS, manual verify, commit.

```bash
git add "Echo macOS/Views/MacSettingsView.swift" "Echo macOS/Views/MacPlayerMoreMenu.swift"
git commit -m "feat(macos): narration voice picker + status entry points"
```

---

## Cross-Cutting: Documentation

- [ ] Update **ARCHITECTURE.md** (narration is now iOS **+ macOS**; the macOS batch `synthesize` stage; the DB-driven narrated-track playback path; `NarrationCache`/`NarrationEngineFactory`; Schema V21), **README.md** (Mac can now narrate EPUBs overnight), **CHANGELOG.md** (per-feature entries). Use the `doc-sync` skill. Note m4b export remains iOS-only.

```bash
git add ARCHITECTURE.md README.md CHANGELOG.md
git commit -m "docs: macOS on-device narration + overnight EPUB narration queue"
```

---

## Dependency Graph

```
P0 (spike) ── gates everything; ends in a MANUAL on-device run
├── P0.1 link FluidAudio to macOS target
├── P0.2 de-gate KokoroTTSEngine          ── needs P0.1
└── P0.3 manual synth spike               ── needs P0.2  ← ACCEPTANCE GATE

P1 ── needs P0 green
├── P1.1 relocate cache dir → NarrationCache
└── P1.2 engine factory + delete spike    ── needs P1.1

P2 ── needs P1
├── P2.1 Schema V21 (batch_queue.kind)
├── P2.2 EPUB-only enqueue                ── needs P2.1
├── P2.3 synthesize stage                 ── needs P2.1, P1.2
└── P2.4 "Narrate EPUB(s)…" command        ── needs P2.2

P3 (REQUIRED for usability) ── needs P2.3 (something to play)
├── P3.1 pure track ordering (tested)
├── P3.2 MacPlayerModel.loadNarratedBook  ── needs P3.1
└── P3.3 open from queue                  ── needs P3.2

P4 ── needs P3
├── P4.1 port 3 narration views
└── P4.2 entry points                     ── needs P4.1
```

## Testing Strategy

| Task | Suite / Method | Covers |
|------|----------------|--------|
| P0.2 | macOS build | KokoroTTSEngine compiles on macOS |
| P0.3 | **Manual, on device** | Real Kokoro synth + model download under sandbox (the gate) |
| P1.1 | `NarrationCacheTests` | Cache dir relocated, path unchanged |
| P2.1 | `BatchQueueDAOTests` | `kind` column round-trips, defaults to align |
| P2.2–P2.4 | macOS build + manual enqueue | EPUB-only enqueue + synthesize stage advance |
| P3.1 | `NarrationTrackOrderingTests` | TrackRecord rows → ordered URLs |
| P3.2–P3.3, P4 | macOS build + manual playback/UI | Narrated book plays; UI drives it |

Commands: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`; macOS `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build` (single invocation — never two `xcodebuild`s at once, never parallel testing; 16 GB machine). Run `cross-platform-parity-reviewer` after Shared/ changes (P1, P3.1) and `schema-migration-reviewer` after P2.1.

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Kokoro/FluidAudio runtime fails on this Mac (only unverified thing) | Low | **P0.3 is the cheap, first on-hardware test** — stop there if it fails |
| HuggingFace model download blocked under App Sandbox | Low | `network.client` present, cache lands in-container; P0.3 confirms first-run |
| macOS playback discovery under-scoped (files render but won't play) | Medium | P3 is explicitly required + sequenced before P4; pure ordering unit-tested |
| iOS narration orchestration not reusable on macOS | Certain (by design) | Don't port `PlayerModel+Narration`; re-express against `MacPlayerModel`'s AVPlayer (P3.2) — simpler, no render-ahead |
| Swift-6 isolation across `@MainActor NarrationService` ↔ actor engine ↔ GRDB | Medium | Engine is an actor; service `@MainActor`; keep DB writes on the writer; build-gate catches violations |
| Overnight synthesis heavier than align (memory/disk/cancellation) | Medium | Reuse `BatchQueueRunner` failure isolation + restart recovery; stream-to-sink keeps peak memory low; per-chapter progress + cancellation |
| `project.pbxproj` edit corrupts the project (P0.1, P4.1) | Medium | Prefer Xcode GUI target membership; verify ids before manual edits; resolve+build before commit; BLOCKED over corruption |
| A14-class ANE trap on some Mac SoC | Low | FluidAudio 0.15.4 `ane-tail-gpu` routing runs on all Apple Silicon; P0.3 catches a regression |

## Deferred / Out of Scope

- **M4B chapter export on macOS** — `ChapterMarkerWriter`/`swift-audio-marker`-on-macOS is unverified; per the v1 decision, ship playback only. Revisit by linking `AudioMarker` to the macOS target and un-gating `ChapterMarkerWriter` (it throws `unavailableOnPlatform` off-iOS today).
- **`audiobookID` portability** — narrate items derive a device-local id from the EPUB's parent dir, consistent with today's scheme; a portable-id fix is tracked separately.
- **A15+/A14 gating logic** — stays iPhone-only; Macs need no SoC gate.

## Self-Review

- **Decisions honored:** runtime model download (P0/P2.3 use `NarrationEngineFactory` → `KokoroTTSEngine`, FluidAudio downloads; no bundling task); playback-only/defer export (no export task; called out in Deferred); dedicated "Narrate EPUB(s)…" command (P2.4); no Mac SoC gate (P1.2 note + Deferred); one synthesize stage in the existing queue (P2.3 branches `makeStages`).
- **Scope coverage:** P0 engine bring-up, P1 seam/cache, P2 batch+enqueue+command, P3 the playback discovery gap (the scope's flagged structural risk), P4 UI. Each scope phase maps to a phase here.
- **Type consistency:** `TTSEngine`/`TTSChunk`/`VoiceID`, `NarrationService.renderChapter(chapterIndex:chapterNumber:blocks:voice:)`, `NarrationCache.directory()`, `NarrationEngineFactory.make()`, `BatchItemKind`/`batch_queue.kind`, `NarrationTrackOrdering.orderedFileURLs`, `MacPlayerModel.loadNarratedBook` — used consistently.
- **Verify-before-coding points (flagged inline, not placeholders):** exact `NarrationService.init` + `NarrationChapterPlanner` API (P0.3/P2.3); `TrackRecord` initializer (P3.1); the `project.pbxproj` FluidAudio/exception ids (P0.1/P4.1); `narrationCacheDirectory` body to move (P1.1).
- **Schema correctness:** V21 (not editing the now-shipped V20); additive `ALTER ADD … DEFAULT` — no re-import forced.
