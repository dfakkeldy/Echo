# Design: `echo-cli` — headless narration on macOS (Phase 1: `narrate`)

Date: 2026-06-22
Status: Approved design → spec for implementation planning
Scope: **Phase 1 only — the `narrate` subcommand.** `align` is Phase 2 (separate spec).

## Problem & goal

Today the only way to narrate an EPUB into a chaptered `.m4b` + read-along
`alignment.json` sidecar headlessly is `EchoTests/NarrationHarness.swift`, an
**iOS-Simulator** test driven by `xcodebuild test-without-building`. That path
works but is awkward: it runs in the memory-bounded iOS simulator (hence the
"≤5 chapters per process, then restart" batching to dodge jetsam OOM), it's a
*test* not a tool, and it's invoked through `xcodebuild`.

Goal: a **native macOS command-line tool** that narrates an EPUB end-to-end with
no simulator, run directly (`echo-cli narrate …`). It becomes the supported way
to produce narrated books (replacing the sim harness for production), and the
foundation for a Phase-2 `align` subcommand.

## Non-goals (Phase 1)

- **Alignment** (`align`): deferred to Phase 2 — it needs a moderate refactor to
  extract a non-GUI engine from the `@MainActor` `AutoAlignmentService` +
  `MacAlignmentService`. Not in this spec.
- **`--speed`**: the engine stays at the fixed `speed = 1.0`. (Decided.)
- **Distribution** (Homebrew, notarized standalone binary): out of scope. The
  tool links ONNX/MisakiSwift statically via the Xcode project; standalone
  redistribution is a later concern.
- **App-Store packaging / sandbox entitlements**: a dev/production tool run
  locally, not shipped through the store.

## Why headless narration is feasible with no refactor

A context pass over the codebase confirmed every narration component is already
`#if os(macOS)`-clean and macOS-capable (and the **Echo macOS app already
compiles `EchoCore` for macOS**, so a macOS CLI inherits a known-good compile):

- `EPUBImportService.import(...)` — no isolation, returns `[EPubBlockRecord]`.
- `DatabaseService.init(inMemory:)` — GRDB, multiplatform.
- `NarrationService.renderChapter(...)` — `@MainActor`, but callable from a
  `@MainActor`/`await` context (the harness proves the sequence).
- `OnnxKokoroEngine` — `actor`, CPU ONNX, downloads `model_fp16.onnx` at runtime
  (no AOT/ANE, no simulator).
- `AudioExportService.exportM4B(...)` — `actor`, cross-platform.
- `AlignmentSidecar` — pure Foundation.

The `@MainActor` isolation on `NarrationService`/`DatabaseService` is **not** a
blocker: `HeadlessNarrationRunner` is `@MainActor`, and the CLI command simply
`await`s it, which hops to the main actor automatically. The heavy synthesis runs
off-main on the `OnnxKokoroEngine` actor.

## Architecture

Two pieces:

### 1. `HeadlessNarrationRunner` (new, `EchoCore`, `@MainActor`)

Extract the ~80 lines of orchestration currently inlined in
`NarrationHarness.swift` into a reusable, unit-testable type in `EchoCore`
(so it compiles into iOS + macOS + the CLI). The CLI becomes a thin wrapper, and
the existing iOS-sim harness can later call the same runner (DRY).

```swift
struct NarrationRunConfig {
    var epubURL: URL            // EPUB dir or .epub zip
    var outM4BURL: URL
    var sidecarURL: URL?        // nil → skip sidecar
    var workDir: URL            // intermediates (.m4a + .anchors-ch<N>.json)
    var voice: VoiceID          // default af_heart
    var title: String
    var author: String
    var maxNewChaptersPerRun: Int?   // nil → whole book in one process
}

enum NarrationRunProgress {
    case importing
    case chapter(index: Int, of: Int, fraction: Double)
    case exporting
    case wroteSidecar(anchors: Int)
}

struct NarrationRunResult {
    var outM4BURL: URL
    var chapters: Int
    var durationSeconds: Double
    var capturedThisRun: Int
    var complete: Bool          // false → batch progress, re-run to continue
}

@MainActor
final class HeadlessNarrationRunner {
    func run(_ config: NarrationRunConfig,
             tts: TTSEngine? = nil,                 // injectable for tests; default OnnxKokoroEngine
             progress: @MainActor (NarrationRunProgress) -> Void = { _ in }
    ) async throws -> NarrationRunResult
}
```

Behavior (mirrors `NarrationHarness.narrateAndExport`, lines 67–249):
1. in-memory `DatabaseService`; insert the `audiobook` row.
2. `EPUBImportService.import` → blocks grouped by `chapterIndex`.
3. crash-partial cleanup: drop any `.m4a` whose `.anchors-ch<N>.json` is missing.
4. render up to `maxNewChaptersPerRun` *uncaptured* chapters via
   `NarrationService.renderChapter`; after each, read its synthesized anchors +
   track duration and write `.anchors-ch<N>.json`.
5. if chapters remain uncaptured → return `complete: false` (resume by re-running).
6. else → `AudioExportService.exportM4B` (chaptered, cover from EPUB front-matter)
   then assemble the portable sidecar (per-chapter relative times + cumulative
   offsets via `AlignmentSidecar.portableSuffix`) and `AlignmentSidecar.write`.

Pronunciation overrides: pass `{ PronunciationOverrideStore.shared.overrides() }`
to `NarrationService` (same as both app call sites) so built-ins (e.g. Fakkeldy)
and user entries apply.

### 2. `echo-cli` (new macOS Command-Line Tool target)

`@main` + `swift-argument-parser` (already a project dependency). Git-style:
one binary, subcommands (`narrate` now, `align` Phase 2).

```
echo-cli narrate --epub <dir|.epub> --out <book.m4b>
                 [--sidecar <book.alignment.json>]
                 [--voice af_heart]
                 [--title "…"] [--author "…"]
                 [--work-dir <dir>]      # default: alongside --out
                 [--max-chapters N]      # default: whole book in one process
                 [--resume]              # continue from existing .anchors markers
```

- Builds a `NarrationRunConfig`, calls `HeadlessNarrationRunner.run`, prints
  progress + per-chunk RTF to stderr, prints the result summary to stdout.
- Exit code: `0` on `complete: true`; non-zero on error; a distinct code for
  `complete: false` (batch progress, more runs needed).
- **Whole book in one process by default** — native macOS has no jetsam cap, and
  `NarrationService` streams each sub-chunk straight to disk (peak memory ≈ one
  sub-chunk), so a 17-chapter book in one process is fine. `--max-chapters`
  exists for the cautious/low-RAM case; `.anchors-ch` markers make it resume-safe.

## Build wiring (the fiddly part)

Model the new target on the existing **Echo macOS** app target, minus app-only
bits:

- New target `echo-cli`, product type `com.apple.product-type.tool` (bare
  executable), macOS deployment target matching the app.
- **Source membership**: add `echo-cli` to the membership of the `EchoCore` and
  `Shared` `PBXFileSystemSynchronizedRootGroup`s (the same mechanism the app
  targets use — `EchoCore` is compiled per-target, not a framework). iOS-only
  files compile out via their `#if os(iOS)` gates. Do **not** add the
  `Echo macOS/` app sources (MacBatchProcessingService etc.) — the narrate path
  needs only `EchoCore` + `Shared`.
- **SPM products to link**: GRDB, MisakiSwift, onnxruntime, ZIPFoundation,
  swift-audio-marker (AudioMarker), swift-argument-parser. **Not** WhisperKit
  (that's Phase-2 `align`).
- **Omit** the "Strip statically-linked onnxruntime frameworks (ITMS-90208)"
  shell-script phase — it's an App-Store packaging fix; a CLI doesn't embed
  frameworks. (Keep `ENABLE_USER_SCRIPT_SANDBOXING` irrelevant since no script.)
- **Code signing**: ad-hoc sign for local dev (`CODE_SIGN_IDENTITY = "-"`), no
  entitlements/sandbox. Re-evaluate if distributed later.

## Risks / decisions to resolve during implementation

1. **Resource loading is the #1 risk.** The narration front-end loads
   `_kokoro_vocab.json` (`KokoroPhonemeVocab`), `us_gold.json`/`us_silver.json`
   (`DataResourcesUtil`), and `af_heart.f32`/`.rows` (`KokoroVoicePack`) via
   `Bundle.main`. A bare CLI tool has no `.app` bundle, so `Bundle.main` resolves
   to the **executable's directory**. Plan:
   - **Primary**: add those resources to the `echo-cli` target's resources so they
     land next to the binary, and verify `Bundle.main.url(forResource:…)` finds
     them for a `product-type.tool`. A 10-minute spike at the start of
     implementation settles this.
   - **Fallback** (if a bare tool can't carry `Bundle.main` resources): add a
     single injectable resource-directory seam — an `ECHO_RESOURCE_DIR` env var
     (or a `--resources` flag) honored by the three loaders, defaulting to
     `Bundle.main` so the app is unaffected. Small, contained `EchoCore` change.
   - The 163 MB `model_fp16.onnx` is **not** a bundle resource — it's downloaded
     at runtime to `NarrationCache.directory()/Models/kokoro-onnx-v6/`, which
     works on macOS. (A `--model` override could point at an already-downloaded
     copy to skip the download; optional.)
2. **`pbxproj` surgery**: adding a target + synchronized-group membership + SPM
   product dependencies by hand is error-prone. Mirror the `Echo macOS` target's
   `EchoCore`/`Shared` membership and package-product links exactly, then prune.
3. **`@MainActor` + ArgumentParser**: `AsyncParsableCommand.run()` stays
   nonisolated and `await`s the `@MainActor` runner (auto actor-hop). Verified
   pattern; note it so the implementer doesn't try to annotate `run()` itself.
4. **`maxNewChaptersPerRun` default**: whole-book in one process. If real-world
   macOS runs show memory growth on very long books, fall back to a default cap.

## Testing

- `HeadlessNarrationRunnerTests` (EchoTests, runs on the existing test target):
  inject a **stub `TTSEngine`** (returns short non-silent PCM, no 163 MB model)
  over a tiny 2-chapter fixture EPUB. Assert: `.m4b` produced with 2 chapters,
  sidecar written with the expected anchor count + portable suffixes, `.anchors`
  markers created, and a second `run` with `--resume` semantics skips captured
  chapters (`capturedThisRun == 0`, `complete == true`).
- CLI arg parsing: lightweight `ParsableCommand` parse tests (no synthesis).
- Manual acceptance: `echo-cli narrate` a real EPUB on macOS; confirm m4b
  chapters + sidecar + the silence guard logs; compare silence/transcript to the
  sim-harness output (should match — same `EchoCore` code path).

## Success criteria

- `echo-cli narrate --epub … --out book.m4b --sidecar book.alignment.json`
  produces, on macOS with no simulator, a chaptered `.m4b` + portable sidecar
  identical in structure to the sim-harness output.
- The sim harness can be retired for narration (or refactored to call
  `HeadlessNarrationRunner`).
- New runner unit tests green; existing suites unaffected.
