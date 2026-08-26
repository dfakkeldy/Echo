# echo-cli `narrate` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS command-line tool, `echo-cli narrate`, that turns an EPUB into a chaptered `.m4b` + read-along `.alignment.json` sidecar with no iOS Simulator.

**Architecture:** Extract the sim-harness orchestration into a reusable `@MainActor HeadlessNarrationRunner` in `EchoCore`; add a macOS Command-Line Tool target (`echo-cli`) that wraps it with `swift-argument-parser`. The narration front-end's `Bundle.main` resource loads get an `ECHO_RESOURCE_DIR` override so a bare CLI binary can find the lexicon/vocab/voice-pack.

**Tech Stack:** Swift, Xcode command-line-tool target, swift-argument-parser, GRDB, MisakiSwift, ONNX Runtime, swift-audio-marker.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-22-echo-cli-narrate-design.md`. Phase 1 = `narrate` only; `align` is Phase 2.
- No `--speed`: engine stays at `speed = 1.0`.
- macOS only. Reuse `EchoCore` + `Shared` sources (compiled into the new target via synchronized-group membership — `EchoCore` is not a framework). Do NOT add `Echo macOS/` app sources.
- SPM links: GRDB, MisakiSwift, onnxruntime, ZIPFoundation, swift-audio-marker, swift-argument-parser. NOT WhisperKit.
- Omit the "Strip statically-linked onnxruntime frameworks (ITMS-90208)" phase on the CLI target.
- Every Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- Build/test locally with `CODE_SIGNING_ALLOWED=NO` where needed (known onnxruntime codesign break on Xcode 26.5).
- **Execution branch:** run this plan on a fresh worktree branched off `origin/nightly` (created via `superpowers:using-git-worktrees`), NOT on the PR #144 branch — ideally after #144 merges so the CLI narrates with the silence fix.

---

### Task 1: `ECHO_RESOURCE_DIR` override for narration resources

The narration front-end loads `_kokoro_vocab.json`, `us_gold.json`/`us_silver.json`, and `af_heart.f32`/`.rows` via `Bundle.main`. A bare CLI tool has no `.app` bundle, so add an env-var override that takes precedence over `Bundle.main` (and is a no-op for the app when unset).

**Files:**
- Create: `EchoCore/Services/Narration/NarrationResources.swift`
- Modify: `EchoCore/Services/Narration/KokoroPhonemeVocab.swift:25-32` (vocab load)
- Modify: `EchoCore/Services/Narration/KokoroVoicePack.swift:31-38` (f32/rows load)
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/DataResourcesUtil.swift:6-30` (gold/silver load)
- Test: `EchoTests/NarrationResourcesTests.swift`

**Interfaces:**
- Produces: `enum NarrationResources { static func url(forResource: String, withExtension ext: String) -> URL? }` — returns `<ECHO_RESOURCE_DIR>/<name>.<ext>` if that env var is set and the file exists there, else `Bundle.main.url(forResource:withExtension:)`.

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/NarrationResourcesTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationResourcesTests {
    @Test func envDirTakesPrecedenceWhenFileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("widget.json")
        try Data("{}".utf8).write(to: file)

        setenv("ECHO_RESOURCE_DIR", tmp.path, 1)
        defer { unsetenv("ECHO_RESOURCE_DIR") }

        let url = NarrationResources.url(forResource: "widget", withExtension: "json")
        #expect(url?.path == file.path)
    }

    @Test func fallsBackToBundleWhenEnvUnset() {
        unsetenv("ECHO_RESOURCE_DIR")
        // _kokoro_vocab.json is a real app-bundle resource.
        let url = NarrationResources.url(forResource: "_kokoro_vocab", withExtension: "json")
        #expect(url != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && xcodebuild test-without-building -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/NarrationResourcesTests -parallel-testing-enabled NO`
Expected: FAIL — `cannot find 'NarrationResources' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// EchoCore/Services/Narration/NarrationResources.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves a bundled narration resource, allowing an `ECHO_RESOURCE_DIR`
/// environment override so a bare command-line tool (no `.app` bundle) can find
/// the lexicon / phoneme vocab / voice-pack files. The override wins only when it
/// is set AND the file exists there; otherwise this is exactly `Bundle.main`.
enum NarrationResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS (2 tests).

- [ ] **Step 5: Retrofit the two EchoCore loaders**

In `KokoroPhonemeVocab.swift`, replace `Bundle.main.url(forResource: "_kokoro_vocab", withExtension: "json")` with `NarrationResources.url(forResource: "_kokoro_vocab", withExtension: "json")`.

In `KokoroVoicePack.swift`, replace the two `Bundle.main.url(forResource: name, withExtension: "f32")` / `"rows"` calls with `NarrationResources.url(forResource: name, withExtension: …)`.

- [ ] **Step 6: Retrofit the MisakiSwift loader (separate module — inline the same check)**

In `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/DataResourcesUtil.swift`, add a private helper and use it in `loadGold`/`loadSilver` instead of `Bundle.main.url`:

```swift
private static func resourceURL(_ name: String) -> URL? {
    if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
        let c = URL(fileURLWithPath: dir).appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: c.path) { return c }
    }
    return Bundle.main.url(forResource: name, withExtension: "json")
}
```
Replace `Bundle.main.url(forResource: filename, withExtension: "json")` with `resourceURL(filename)` in both functions.

- [ ] **Step 7: Verify package + app still build, then commit**

Run: `cd ThirdParty/MisakiSwift && swift build` (Expected: `Build complete!`), then `make build-tests` (Expected: `** TEST BUILD SUCCEEDED **`).

```bash
git add EchoCore/Services/Narration/NarrationResources.swift EchoCore/Services/Narration/KokoroPhonemeVocab.swift EchoCore/Services/Narration/KokoroVoicePack.swift ThirdParty/MisakiSwift/Sources/MisakiSwift/English/Lexicon/DataResourcesUtil.swift EchoTests/NarrationResourcesTests.swift
git commit -m "feat(narration): ECHO_RESOURCE_DIR override for bundled resources"
```

---

### Task 2: `HeadlessNarrationRunner` (extract harness orchestration)

**Files:**
- Create: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Test: `EchoTests/HeadlessNarrationRunnerTests.swift`
- Reference (do not import): `EchoTests/NarrationHarness.swift:67-249` (the orchestration being extracted)

**Interfaces:**
- Consumes: `EPUBImportService.import`, `DatabaseService.init(inMemory:)`, `NarrationService.renderChapter`, `OnnxKokoroEngine`/`TTSEngine`, `AudioExportService.exportM4B`, `AlignmentSidecar.write`/`portableSuffix`, `AlignmentAnchorRecord`, `TrackRecord`, `EPubBlockRecord`, `VoiceID`, `ExportItem`, `ExportMetadata`, `PronunciationOverrideStore`.
- Produces:
  ```swift
  struct NarrationRunConfig {
      var epubURL: URL; var outM4BURL: URL; var sidecarURL: URL?
      var workDir: URL; var voice: VoiceID; var title: String; var author: String
      var maxNewChaptersPerRun: Int?
  }
  enum NarrationRunProgress: Sendable {
      case importing
      case chapter(index: Int, of: Int, fraction: Double)
      case exporting
      case wroteSidecar(anchors: Int)
  }
  struct NarrationRunResult { var outM4BURL: URL; var chapters: Int; var durationSeconds: Double; var capturedThisRun: Int; var complete: Bool }
  @MainActor final class HeadlessNarrationRunner {
      func run(_ config: NarrationRunConfig, tts: TTSEngine? = nil,
               progress: @MainActor (NarrationRunProgress) -> Void = { _ in }) async throws -> NarrationRunResult
  }
  ```

- [ ] **Step 1: Write the failing integration test (stub engine + fixture EPUB)**

```swift
// EchoTests/HeadlessNarrationRunnerTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct HeadlessNarrationRunnerTests {
    /// Stub TTS: returns 0.2s of quiet-but-nonzero PCM per call (no 163 MB model).
    private final class StubEngine: TTSEngine {
        func prepare() async throws {}
        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws { progress(.ready) }
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            TTSChunk(samples: [Float](repeating: 0.1, count: 4800), sampleRate: 24_000, duration: 0.2)
        }
    }

    @Test func producesM4BAndSidecarAndResumes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)   // see Step 3 helper
        let out = tmp.appendingPathComponent("book.m4b")
        let sidecar = tmp.appendingPathComponent("book.alignment.json")
        let cfg = NarrationRunConfig(epubURL: epub, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("work"), voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester", maxNewChaptersPerRun: nil)

        let result = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(result.complete)
        #expect(result.chapters == 2)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0.blockId.contains("-b") })  // portable s<i>-b<j>

        // Resume: a second run captures nothing new and is still complete.
        let again = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(again.capturedThisRun == 0)
        #expect(again.complete)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && xcodebuild test-without-building -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/HeadlessNarrationRunnerTests -parallel-testing-enabled NO`
Expected: FAIL — `cannot find 'HeadlessNarrationRunner'` / `TestEPUBFixture` in scope.

- [ ] **Step 3: Add the EPUB fixture helper**

Create `EchoTests/Support/TestEPUBFixture.swift` with a `static func twoChapters(in dir: URL) throws -> URL` that writes a minimal expanded EPUB (mimetype, `META-INF/container.xml`, `OEBPS/content.opf` with a spine of 2 chapter XHTML files each containing 2 `<p>` blocks, and an `OEBPS/nav.xhtml`). Mirror the structure under `/tmp/gh-epub/OEBPS` (a known-good Echo-authored EPUB). Return the expanded directory URL.

- [ ] **Step 4: Implement `HeadlessNarrationRunner`**

Port `NarrationHarness.narrateAndExport` (lines 67-249) verbatim into `run(_:tts:progress:)`, with these substitutions:
- read config from the `NarrationRunConfig` param instead of the JSON job;
- use `tts ?? NarrationEngineFactory.make()` for the engine;
- emit `progress(.importing)` / `.chapter(…)` / `.exporting` / `.wroteSidecar(…)` at the matching points;
- pass `pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() }` into `NarrationService`;
- honor `maxNewChaptersPerRun` (nil ⇒ all uncaptured chapters this run);
- return `NarrationRunResult` (set `complete` from whether any chapter remained uncaptured after the batch).
Keep the `.anchors-ch<N>.json` capture + crash-partial cleanup + cumulative-offset sidecar assembly exactly as the harness does.

- [ ] **Step 5: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/HeadlessNarrationRunnerTests.swift EchoTests/Support/TestEPUBFixture.swift
git commit -m "feat(narration): reusable HeadlessNarrationRunner extracted from the harness"
```

- [ ] **Step 7: (Optional, same commit allowed) point the sim harness at the runner**

Refactor `EchoTests/NarrationHarness.swift` so `narrateAndExport` builds a `NarrationRunConfig` from its JSON job and calls `HeadlessNarrationRunner().run(...)`, deleting the now-duplicated inline orchestration. Re-run `-only-testing:EchoTests` narration suites; expect no regressions. Commit.

---

### Task 3: Create the `echo-cli` macOS tool target + build wiring

This task is Xcode-project surgery; it is verified by *building and running*, not a unit test.

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj` (new target + memberships + package products + copy-resources phase)
- Create: `Tools/echo-cli/main.swift`

- [ ] **Step 1: Add a macOS Command Line Tool target `echo-cli`**

In Xcode: File ▸ New ▸ Target ▸ macOS ▸ Command Line Tool, name `echo-cli`, language Swift, set its source folder to `Tools/echo-cli/`. Set the macOS deployment target equal to the `Echo macOS` target.

- [ ] **Step 2: Give it the shared sources**

Add `echo-cli` to the target membership of the `EchoCore` and `Shared` file-system-synchronized groups (Project navigator ▸ select the group ▸ File Inspector ▸ Target Membership ▸ check `echo-cli`). Do NOT add `Echo macOS/` sources.

- [ ] **Step 3: Link the package products**

Target `echo-cli` ▸ General ▸ Frameworks and Libraries ▸ add: GRDB, MisakiSwift, onnxruntime, ZIPFoundation, AudioMarker (swift-audio-marker), ArgumentParser. Do NOT add WhisperKit. Do NOT add the onnxruntime strip-frameworks Run Script phase.

- [ ] **Step 4: Copy narration resources next to the binary + set signing**

Add a Copy Files build phase (Destination: Products Directory, Subpath: `EchoNarrationResources`) that copies `_kokoro_vocab.json`, `us_gold.json`, `us_silver.json`, `af_heart.f32`, `af_heart.rows` (find their current resource locations under `EchoCore/` via `git ls-files | grep -E '_kokoro_vocab|us_gold|us_silver|af_heart'`). Set `CODE_SIGN_IDENTITY = "-"` (ad-hoc) and no entitlements on the target.

- [ ] **Step 5: Trivial entry point that sets the resource dir**

```swift
// Tools/echo-cli/main.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Point the resource loaders at the copied-alongside resources unless overridden.
if ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil {
    let dir = Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources")
    setenv("ECHO_RESOURCE_DIR", dir.path, 1)
}
print("echo-cli 0.1")
```

- [ ] **Step 6: Build and run to verify**

Run: `xcodebuild build -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. Then run the produced binary (path from `-showBuildSettings | grep TARGET_BUILD_DIR`); expected stdout: `echo-cli 0.1`.

- [ ] **Step 7: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj Tools/echo-cli/main.swift
git commit -m "build(echo-cli): macOS command-line-tool target wired to EchoCore"
```

---

### Task 4: The `narrate` subcommand

**Files:**
- Modify: `Tools/echo-cli/main.swift` (replace trivial main with ArgumentParser root)
- Create: `Tools/echo-cli/NarrateCommand.swift`
- Test: `EchoTests/NarrateCommandParsingTests.swift` (parsing only — runs in the EchoTests target which already links ArgumentParser)

**Interfaces:**
- Consumes: `HeadlessNarrationRunner`, `NarrationRunConfig`, `VoiceID`.
- Produces: `struct EchoCLI: AsyncParsableCommand` (root, subcommands `[NarrateCommand.self]`) and `struct NarrateCommand: AsyncParsableCommand` with options `--epub`, `--out`, `--sidecar?`, `--voice` (default `af_heart`), `--title`, `--author`, `--work-dir?`, `--max-chapters?`, `--resume`.

- [ ] **Step 1: Write the failing parse test**

```swift
// EchoTests/NarrateCommandParsingTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Testing

@testable import Echo   // NarrateCommand must be visible to tests; see Step 3 note

@Suite struct NarrateCommandParsingTests {
    @Test func parsesRequiredAndDefaults() throws {
        let c = try NarrateCommand.parse(["--epub", "/b.epub", "--out", "/b.m4b", "--title", "T", "--author", "A"])
        #expect(c.epub == "/b.epub")
        #expect(c.out == "/b.m4b")
        #expect(c.voice == "af_heart")   // default
        #expect(c.sidecar == nil)
        #expect(c.resume == false)
    }
}
```

> Note: so the parsing struct is testable, define `NarrateCommand` in a file that is a member of BOTH `echo-cli` and `EchoTests` targets (Target Membership), or move its option struct into `EchoCore`. Pick whichever keeps `main.swift` thin; the plan assumes shared membership of `NarrateCommand.swift`.

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && xcodebuild test-without-building -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/NarrateCommandParsingTests -parallel-testing-enabled NO`
Expected: FAIL — `cannot find 'NarrateCommand'`.

- [ ] **Step 3: Implement the command**

```swift
// Tools/echo-cli/NarrateCommand.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

struct NarrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "narrate",
        abstract: "Narrate an EPUB into a chaptered .m4b + alignment sidecar.")

    @Option(help: "EPUB directory or .epub file.") var epub: String
    @Option(help: "Output .m4b path.") var out: String
    @Option(help: "Sidecar .alignment.json path (optional).") var sidecar: String?
    @Option(help: "Kokoro voice id.") var voice: String = "af_heart"
    @Option var title: String
    @Option var author: String
    @Option(name: .customLong("work-dir"), help: "Intermediates dir (default: next to --out).") var workDir: String?
    @Option(name: .customLong("max-chapters"), help: "Chapters per process (default: whole book).") var maxChapters: Int?
    @Flag(help: "Continue from existing .anchors markers.") var resume = false

    @MainActor func run() async throws {
        let outURL = URL(fileURLWithPath: out)
        let work = workDir.map { URL(fileURLWithPath: $0) }
            ?? outURL.deletingLastPathComponent().appendingPathComponent("work-\(outURL.deletingPathExtension().lastPathComponent)")
        let cfg = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: epub), outM4BURL: outURL,
            sidecarURL: sidecar.map { URL(fileURLWithPath: $0) }, workDir: work,
            voice: VoiceID(voice), title: title, author: author,
            maxNewChaptersPerRun: maxChapters)
        let result = try await HeadlessNarrationRunner().run(cfg) { p in
            FileHandle.standardError.write(Data("\(p)\n".utf8))
        }
        if result.complete {
            print("DONE \(result.outM4BURL.path) — \(result.chapters) chapters, \(Int(result.durationSeconds))s")
        } else {
            print("PARTIAL — \(result.capturedThisRun) captured this run; re-run to continue")
            throw ExitCode(2)
        }
    }
}
```

Replace `main.swift` body with the root command (keep the `ECHO_RESOURCE_DIR` setup before parsing):

```swift
// Tools/echo-cli/main.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

if ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"] == nil {
    setenv("ECHO_RESOURCE_DIR", Bundle.main.bundleURL.appendingPathComponent("EchoNarrationResources").path, 1)
}

struct EchoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo-cli", abstract: "Echo narration/alignment tools.",
        subcommands: [NarrateCommand.self])
}
await EchoCLI.main()
```

- [ ] **Step 4: Run the parse test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Build the CLI, commit**

Run: `xcodebuild build -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`. Then `<binary> narrate --help` prints the option list.

```bash
git add Tools/echo-cli/NarrateCommand.swift Tools/echo-cli/main.swift EchoTests/NarrateCommandParsingTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(echo-cli): narrate subcommand"
```

- [ ] **Step 6: Manual acceptance (real EPUB, real model)**

Run the built binary against a real expanded EPUB:
`<binary> narrate --epub /path/to/expanded-epub --out /tmp/x.m4b --sidecar /tmp/x.alignment.json --title "X" --author "Y"`
Expected: it downloads the model once (first run), logs per-chunk RTF + any `Silent … retrying/splitting` lines, and writes a 17-ish-chapter `.m4b` + sidecar. Verify with `ffprobe -show_chapters /tmp/x.m4b` (chapters present) and, optionally, the transcript-vs-EPUB diff used for git-happens (expect ≈0.99 ratio, ≤~6% silence). This output must match the sim-harness output for the same book.

---

## Self-Review

**Spec coverage:**
- Resource loading risk → Task 1 (the `ECHO_RESOURCE_DIR` seam = the spec's "Plan B", chosen for determinism). ✓
- `HeadlessNarrationRunner` → Task 2. ✓
- `echo-cli` target + build wiring (membership, SPM links, skip strip, signing) → Task 3. ✓
- `narrate` subcommand + flags + whole-book/resume → Task 4. ✓
- Testing (runner stub-engine test, parse tests, manual acceptance) → Tasks 2/4. ✓
- Non-goals (align, --speed, distribution) → respected (not in any task). ✓

**Placeholder scan:** No TBD/TODO. Task 3 is imperative Xcode steps (not TDD) by necessity, each with a build/run verification — acceptable for project surgery. The fixture EPUB (Task 2 Step 3) and resource-file locations (Task 3 Step 4) are described with the exact `git ls-files` query to find paths rather than guessed paths.

**Type consistency:** `NarrationRunConfig` / `NarrationRunProgress` / `NarrationRunResult` / `HeadlessNarrationRunner.run` signatures are identical in Task 2's Interfaces, its implementation, and Task 4's consumer. `NarrateCommand` option names match between Task 4 Steps 1 and 3.
