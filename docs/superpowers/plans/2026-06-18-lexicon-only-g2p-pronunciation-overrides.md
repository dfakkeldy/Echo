# Lexicon-Only G2P + User Pronunciation Overrides Implementation Plan

> **STATUS: ✅ IMPLEMENTED 2026-06-18** on `feature/kokoro-fixed-shape`. Part A (MLX removal / lexicon-only G2P) and Part B (pronunciation overrides) are complete and committed. **Deviation from plan:** B3 applies overrides at the text layer inside `NarrationService` (after `TextNormalizer`, before `NarrationTextChunker`) rather than threading an `overrides` parameter through `KokoroFixedShapeEngine` — cleaner (the `TTSEngine` protocol and engine stay untouched) and verified chunk-safe by regression tests in `NarrationServiceTests`. B4's view lives in `EchoCore/Views/` (the plan's `EchoCore/UI/` path doesn't exist) and is excluded from the macOS target via the EchoCore membership-exception set. Verification: full sim suite (619 tests) green including the previously-MLX-blocked Kokoro suites; iOS-device, macOS, and watchOS targets all build.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the MLX dependency from narration by dropping MisakiSwift's BART OOV-fallback network (lexicon-only G2P), and add a user-editable pronunciation dictionary that overrides G2P for chosen words — closing the OOV gap that BART previously filled.

**Architecture:** Two independent changes on the `feature/kokoro-fixed-shape` branch. (A) Lexicon-only: delete MisakiSwift's `FallbackNetwork/` (the 8 BART files — the only MLX users), make the two force-unwrap loads in `EnglishFallbackNetwork` non-fatal so a missing BART model degrades gracefully, then remove `mlx-swift` from the project entirely. This unblocks the iOS-sim test host (upstream mlx-swift #341). (B) Pronunciation overrides: a per-book + global `overrides.json` (`{"Kubernetes": "kuːbərˈnɛtɪs"}`) that rewrites each chunk's words into Misaki's native `[word](/ipa/)` link syntax before G2P — the override always wins (rating 5), bypassing lexicon and the (now-removed) fallback.

**Tech Stack:** Swift 6.2, SwiftUI (`@Observable`), Foundation, vendored MisakiSwift (lexicon-only), the existing `TTSEngine`/`NarrationService` seam. No new third-party deps; `mlx-swift` is removed.

---

## Background — what this plan assumes

This plan builds on the committed `feature/kokoro-fixed-shape` work (Phases 1–4 of the 2026-06-18 fixed-shape Kokoro swap). It assumes these types already exist and compile:

- `KokoroG2P` (`EchoCore/Services/Narration/KokoroG2P.swift`) — wraps `EnglishG2P(british: false).phonemize(text:)`.
- `KokoroFixedShapeEngine.PipelineInputs.make(text:voice:)` — calls `KokoroG2P().phonemes(for: text)`.
- `TextNormalizer.normalize(_:)` (`EchoCore/Services/Narration/TextNormalizer.swift`) — runs *before* G2P in `NarrationService`'s chunk path.
- `NarrationCache.directory()` (`EchoCore/Services/Narration/NarrationCache.swift`) → `Application Support/Narration/`.
- Vendored `ThirdParty/MisakiSwift/` with US-only resources already relocated into `EchoCore/Services/Narration/MisakiResources/`.
- `import Echo` (not `EchoCore`) is the test convention — `EchoCore/` is synced into the `Echo` target via `fileSystemSynchronizedGroups`.

**The MLX problem this solves:** `mlx-swift` 0.30.2 has upstream bug [#341](https://github.com/ml-explore/mlx-swift/issues/341) — the C++ backend references `_MTLIOErrorDomain` / `_MTLTensorDomain`, undefined on the iOS Simulator. This blocks the *entire* iPhone-17-sim test suite (every test transitively links MLX via `EchoCore → KokoroG2P → MisakiSwift → MLX`). Real iOS device, macOS, and watchOS builds succeed. Removing MLX unblocks sim tests.

**The OOV behavior after MLX is gone:** Misaki's `EnglishFallbackNetwork.init` force-unwraps its config/weights loads (lines 17–18). If the BART files are absent, init **crashes**. Even after making it non-fatal, OOV words (not in `us_gold`/`us_silver` lexicons) currently get BART's guess; without BART they emit `unk` ("❓"), which `KokoroPhonemeVocab` drops → **silence**. The pronunciation-override feature closes this gap for the words users actually care about (proper nouns, tech terms).

## File Structure

**Lexicon-only (Part A):**
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift` — make config/weights loads optional, return `("❓", 1)` when absent (graceful degradation instead of crash).
- Delete: the other 7 `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/*.swift` files (BARTModel, BARTEncoderLayer, BARTDecoderLayer, BARTLayerNorm, FeedForward, MultiHeadAttention, and any helper) — these are the only `import MLX` sites.
- Delete: `EchoCore/Services/Narration/MisakiResources/us_bart.safetensors` and `us_bart_config.json` (~12–18 MB binary saving).
- Modify: `ThirdParty/MisakiSwift/Package.swift` — drop the `mlx-swift` dependency + the `MLX`/`MLXNN` products.
- Modify: `Echo.xcodeproj/project.pbxproj` — remove the `mlx-swift` package reference + the 2 `MLX` product dependencies (iOS + macOS targets).
- Modify: `ACKNOWLEDGEMENTS.md` — remove the mlx-swift line.

**Pronunciation overrides (Part B):**
- Create: `EchoCore/Services/Narration/PronunciationOverrides.swift` — loads/merges global + per-book override maps, rewrites text into `[word](/ipa/)` links.
- Create: `EchoCore/Services/Narration/PronunciationOverrideStore.swift` — `@MainActor @Observable` model that owns the editable maps, persists to `Application Support/Narration/Pronunciations/`, and vends a Settings UI binding.
- Modify: `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift` — `PipelineInputs.make` accepts an optional `PronunciationOverrides` and rewrites before G2P.
- Modify: `EchoCore/Services/Narration/NarrationService.swift` — inject the store into the chunk→synthesize path.
- Create: `EchoCore/UI/PronunciationDictionaryView.swift` — SwiftUI list to add/edit/delete global overrides.
- Modify: the Settings screen (locate via the existing settings entry point) — add a "Pronunciation" row.

**Tests:**
- Create: `EchoTests/PronunciationOverridesTests.swift`
- Create: `EchoTests/PronunciationOverrideStoreTests.swift`
- Create: `EchoTests/LexiconOnlyG2PTests.swift`

---

## Part A — Lexicon-only G2P (drop MLX)

### Task A1: Graceful-degradation BART stub

Make `EnglishFallbackNetwork` non-crashing when the BART model is absent, so deleting the BART files (Task A3) degrades to OOV→`unk` instead of a force-unwrap crash.

**Files:**
- Modify: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift`

- [ ] **Step 1: Read the current file to confirm exact line content**

Read `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift`. Confirm lines 1–95 match the structure: `import MLX`, `import MLXUtilsLibrary`, a stored `model: BARTModel` property, and the `init(british:)` force-unwrapping `loadConfig`/`loadWeights`.

- [ ] **Step 2: Replace the whole file with a graceful-degradation stub**

This stub keeps the type and its `callAsFunction` seam alive (so `EnglishG2P` still compiles) but removes all MLX references. When the model is absent it returns `("❓", 1)` — the same string `EnglishG2P` already uses as its default `unk`, so downstream behavior is identical to a BART-emitted unknown.

```swift
import Foundation

/// BART OOV-fallback stub. The real neural network (in the other files of this
/// directory, backed by mlx-swift) was removed from Echo to drop the MLX
/// dependency — mlx-swift 0.30.2 has an upstream iOS-Simulator link bug
/// (ml-explore/mlx-swift#341) that blocked the whole sim test suite, and the
/// BART fallback's value on Echo's nonfiction workload is low (it guesses at
/// proper nouns/brands the user can override instead — see
/// PronunciationOverrides).
///
/// This stub keeps the type + `callAsFunction` seam so `EnglishG2P` compiles
/// unchanged. An OOV word returns the `unk` glyph ("❓"), which `KokoroPhonemeVocab`
/// drops → the word is silent. The PronunciationOverrides feature is the
/// supported way to give OOV words a real pronunciation.
final class EnglishFallbackNetwork {
  private let unk: String

  init(british: Bool, unk: String = "❓") {
    self.unk = unk
  }

  func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
    (unk, 1)
  }
}
```

- [ ] **Step 3: Build the iOS device target to confirm the stub compiles**

Run: `xcodebuild -scheme Echo -destination 'generic/platform=iOS' -jobs 5 build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `BUILD SUCCEEDED` (the other FallbackNetwork files still `import MLX`, so the build succeeds *because* `EnglishFallbackNetwork` still transitively pulls MLX via its sibling files — that's fine; we delete those next).

- [ ] **Step 4: Commit**

```bash
git add ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/EnglishFallbackNetwork.swift
git commit -m "refactor(narration): EnglishFallbackNetwork graceful-degradation stub"
```

### Task A2: Delete the MLX-backed BART files

Remove the 7 files that `import MLX` (other than the stub just rewritten). After this, MisakiSwift has zero MLX references.

**Files:**
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/BARTModel.swift`
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/BARTEncoderLayer.swift`
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/BARTDecoderLayer.swift`
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/BARTLayerNorm.swift`
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/FeedForward.swift`
- Delete: `ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/MultiHeadAttention.swift`
- Delete: any other `.swift` file in `FallbackNetwork/` whose only content is MLX-backed BART plumbing.

- [ ] **Step 1: List every file in FallbackNetwork/ to confirm what stays vs goes**

Run: `ls ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/`
Expected: `EnglishFallbackNetwork.swift` (the stub, stays) plus the BART* / FeedForward / MultiHeadAttention files (delete).

- [ ] **Step 2: Confirm each delete-target is MLX-only**

Run: `grep -l "import MLX" ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork/*.swift`
Expected: every file listed EXCEPT `EnglishFallbackNetwork.swift`. Those are the delete targets.

- [ ] **Step 3: Delete the MLX-backed files**

```bash
cd ThirdParty/MisakiSwift/Sources/MisakiSwift/English/FallbackNetwork
rm BARTModel.swift BARTEncoderLayer.swift BARTDecoderLayer.swift BARTLayerNorm.swift FeedForward.swift MultiHeadAttention.swift
```
If `grep -l "import MLX"` in Step 2 listed any additional file, delete it too.

- [ ] **Step 4: Verify zero MLX references remain in MisakiSwift**

Run: `grep -rn "import MLX\|MLXArray\|MLX\." ThirdParty/MisakiSwift/Sources/`
Expected: no output (the `MLXUtilsLibrary` import in EnglishG2P/Lexicon is fine — that package is pure-Swift data structures, no MLX dep).

- [ ] **Step 5: Commit**

```bash
git add -A ThirdParty/MisakiSwift
git commit -m "refactor(narration): delete MLX-backed BART fallback (lexicon-only G2P)"
```

### Task A3: Drop mlx-swift from the MisakiSwift Package.swift

With zero `import MLX` left, remove the dependency declaration.

**Files:**
- Modify: `ThirdParty/MisakiSwift/Package.swift`

- [ ] **Step 1: Read the current Package.swift**

Read `ThirdParty/MisakiSwift/Package.swift`. It currently has:
```swift
dependencies: [
  .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
  .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
],
```
and the MisakiSwift target depends on `MLX`, `MLXNN`, `MLXUtilsLibrary`.

- [ ] **Step 2: Remove the mlx-swift dep + MLX/MLXNN products**

Edit the `dependencies:` array to drop the `mlx-swift` line, and edit the target's `dependencies:` to drop `MLX` and `MLXNN`. Keep `MLXUtilsLibrary` (provides `MToken`/`TokenContext`). The result:

```swift
// swift-tools-version: 6.2
// (existing comment block about vendoring + resource relocation stays)
import PackageDescription

let package = Package(
  name: "MisakiSwift",
  platforms: [ .iOS(.v18), .macOS(.v15) ],
  products: [
    .library(name: "MisakiSwift", type: .dynamic, targets: ["MisakiSwift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
  ],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
      ]
    ),
    .testTarget(name: "MisakiSwiftTests", dependencies: ["MisakiSwift"]),
  ]
)
```

- [ ] **Step 3: Commit**

```bash
git add ThirdParty/MisakiSwift/Package.swift
git commit -m "build(narration): drop mlx-swift dep from MisakiSwift (lexicon-only)"
```

### Task A4: Remove mlx-swift from the Xcode project

Drop the package reference, the 2 product dependencies (iOS + macOS framework phases + the macOS `packageProductDependencies`), and the `MLX in Frameworks` build files.

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`

The MLX-related pbxproj IDs (stable across the feature branch — confirm by grep before editing):
- Package ref: `CC0000000000DMLXS0000000`
- Product deps: `CC0000000000GMLXS0000000` (macOS), `CC0000000000IMLXS0000000` (iOS)
- Build files: `CC0000000000PMLXS0000000` (macOS Frameworks), `CC0000000000QMLXS0000000` (iOS Frameworks)

- [ ] **Step 1: Confirm the current IDs by grepping**

Run: `grep -n "MLXS0000000" Echo.xcodeproj/project.pbxproj`
Note every line; each must be removed in the steps below.

- [ ] **Step 2: Remove the two `MLX in Frameworks` build-file lines**

In the `/* Begin PBXBuildFile section */`, delete the two lines:
```
CC0000000000PMLXS0000000 /* MLX in Frameworks */ = {isa = PBXBuildFile; productRef = CC0000000000GMLXS0000000 /* MLX */; };
CC0000000000QMLXS0000000 /* MLX in Frameworks */ = {isa = PBXBuildFile; productRef = CC0000000000IMLXS0000000 /* MLX */; };
```

- [ ] **Step 3: Remove the two `MLX in Frameworks` references from the framework phases**

In both `PBXFrameworksBuildPhase` blocks (iOS `CC08EC562F9522F600206D2F` and macOS `AA0100000000000000000030`), delete the line:
```
CC0000000000QMLXS0000000 /* MLX in Frameworks */,   // iOS phase
CC0000000000PMLXS0000000 /* MLX in Frameworks */,   // macOS phase
```

- [ ] **Step 4: Remove `MLX` from the macOS `packageProductDependencies`**

In the macOS target's `packageProductDependencies = ( ... )` array, delete:
```
CC0000000000GMLXS0000000 /* MLX */,
```

- [ ] **Step 5: Remove the mlx-swift line from `packageReferences`**

In the project's `packageReferences = ( ... )` array, delete:
```
CC0000000000DMLXS0000000 /* XCRemoteSwiftPackageReference "mlx-swift" */,
```

- [ ] **Step 6: Remove the mlx-swift `XCRemoteSwiftPackageReference` block**

In `/* Begin XCRemoteSwiftPackageReference section */`, delete the whole block:
```
CC0000000000DMLXS0000000 /* XCRemoteSwiftPackageReference "mlx-swift" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/ml-explore/mlx-swift";
    requirement = { kind = exactVersion; version = 0.30.2; };
};
```

- [ ] **Step 7: Remove the two `XCSwiftPackageProductDependency` blocks for MLX**

In `/* Begin XCSwiftPackageProductDependency section */`, delete:
```
CC0000000000GMLXS0000000 /* MLX */ = { ... };
CC0000000000IMLXS0000000 /* MLX */ = { ... };
```

- [ ] **Step 8: Verify zero MLX refs remain**

Run: `grep -n "MLXS0000000" Echo.xcodeproj/project.pbxproj`
Expected: no output.

- [ ] **Step 9: Resolve packages + build iOS device**

Run:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Echo-*/SourcePackages
rm -f Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -scheme Echo -destination 'generic/platform=iOS' -jobs 5 build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED` (MisakiSwift no longer pulls MLX).

- [ ] **Step 10: Build the SIM test target — this is the unblock moment**

Run: `make build-tests 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **` — the mlx-swift #341 symbol error is gone. This is the whole point of Part A.

- [ ] **Step 11: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj
git commit -m "build(narration): remove mlx-swift from Xcode project (sim tests unblocked)"
```

### Task A5: Delete the BART resource files + update attribution

Remove the now-unused ~12–18 MB BART model + config from the app bundle, and drop the mlx-swift attribution line.

**Files:**
- Delete: `EchoCore/Services/Narration/MisakiResources/us_bart.safetensors`
- Delete: `EchoCore/Services/Narration/MisakiResources/us_bart_config.json`
- Modify: `ACKNOWLEDGEMENTS.md`

- [ ] **Step 1: Confirm the files exist and their sizes**

Run: `ls -la EchoCore/Services/Narration/MisakiResources/us_bart*`
Expected: two files; `us_bart.safetensors` is the large one (~12–18 MB).

- [ ] **Step 2: Delete them**

```bash
rm EchoCore/Services/Narration/MisakiResources/us_bart.safetensors
rm EchoCore/Services/Narration/MisakiResources/us_bart_config.json
```

- [ ] **Step 3: Confirm the stub's `loadConfig`/`loadWeights` absence path is what runs**

(The stub from Task A1 doesn't load these at all — it ignores the files. This step is just confirming the deletions don't break compilation.)
Run: `make build-tests 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Remove the mlx-swift line from ACKNOWLEDGEMENTS.md**

Read `ACKNOWLEDGEMENTS.md`, delete the row:
```
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | MIT | Apple MLX array framework — transitive dep of MisakiSwift's BART OOV-fallback network. |
```
Also update the MisakiSwift row to note it's now lexicon-only (BART removed).

- [ ] **Step 5: Commit**

```bash
git add -A EchoCore/Services/Narration/MisakiResources ACKNOWLEDGEMENTS.md
git commit -m "chore(narration): drop us_bart resources (~15MB) post-MLX removal"
```

### Task A6: Lexicon-only G2P smoke test

Pin the new behavior: lexicon words phonemize, OOV words degrade to `unk` (not crash).

**Files:**
- Create: `EchoTests/LexiconOnlyG2PTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct LexiconOnlyG2PTests {

    @Test func lexiconWordPhonemizes() {
        // "hello" is in the gold lexicon.
        let p = KokoroG2P().phonemes(for: "hello")
        #expect(!p.isEmpty)
        #expect(!p.contains("❓")) // no OOV marker on a known word
    }

    @Test func oovWordDegradesGracefullyDoesNotCrash() {
        // An invented proper noun that's in no lexicon and (now) has no BART
        // fallback. It must not crash; it emits the ❓ unk marker.
        let p = KokoroG2P().phonemes(for: "Xyzqwf")
        // The unk glyph appears somewhere in the output (the word slot).
        #expect(p.contains("❓"))
    }

    @Test func mixedLexiconAndOovDoesNotCrash() {
        // Real prose mixes known + unknown words; the whole string must return.
        let p = KokoroG2P().phonemes(for: "The Xyzqwf server restarted.")
        #expect(!p.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to confirm it passes**

Run: `make test-only FILTER=EchoTests/LexiconOnlyG2PTests 2>&1 | grep -E "Test case|passed|failed|TEST"`
Expected: 3 tests pass. (This is the first sim test run since MLX was introduced — its success proves the unblock.)

- [ ] **Step 3: Run the full sim suite to confirm no regressions from the MLX removal**

Run: `make test-only 2>&1 | tail -10`
Expected: the whole `EchoTests` suite passes, including the previously-blocked `KokoroG2PTests`, `KokoroVoicePackTests`, `KokoroFixedShapeEngineTests`.

- [ ] **Step 4: Commit**

```bash
git add EchoTests/LexiconOnlyG2PTests.swift
git commit -m "test(narration): pin lexicon-only G2P behavior (OOV→unk, no crash)"
```

---

## Part B — User Pronunciation Overrides

### Task B1: PronunciationOverrides — pure text rewriter

The pure unit that maps `{"Kubernetes": "kuːbərˈnɛtɪs"}` → text rewriting into Misaki's `[Kubernetes](/kuːbərˈnɛtɪs/)` link syntax. No I/O, no SwiftData — pure and testable.

**Files:**
- Create: `EchoCore/Services/Narration/PronunciationOverrides.swift`
- Test: `EchoTests/PronunciationOverridesTests.swift`

**Why link syntax:** Misaki's `EnglishG2P.preprocess` (lines 137–191) already parses `[text](/phonemes/)` and injects the phonemes with `rating: 5` (highest) — bypassing the lexicon AND the fallback. An override via this syntax always wins and needs zero changes to Misaki internals.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct PronunciationOverridesTests {

    @Test func rewritesWholeWordOnly() throws {
        let ovr = PronunciationOverrides(entries: [
            "Kubernetes": "kuːbərˈnɛtɪs"
        ])
        let out = ovr.apply(to: "Deploying Kubernetes to production.")
        #expect(out == "Deploying [Kubernetes](/kuːbərˈnɛtɪs/) to production.")
    }

    @Test func doesNotRewriteSubstrings() throws {
        // "use" must not match inside "user" or "reuse".
        let ovr = PronunciationOverrides(entries: ["use": "juːz"])
        let out = ovr.apply(to: "the user reuses tokens")
        #expect(!out.contains("[user]"))
        #expect(!out.contains("[reuses]"))
    }

    @Test func caseInsensitiveMatch() throws {
        let ovr = PronunciationOverrides(entries: ["postgres": "ˈpɒstɡrɛs"])
        let out = ovr.apply(to: "Postgres and POSTGRES both match.")
        #expect(out.contains("[Postgres](/ˈpɒstɡrɛs/)"))
        #expect(out.contains("[POSTGRES](/ˈpɒstɡrɛs/)"))
    }

    @Test func mergesGlobalAndPerBookBookWins() throws {
        let ovr = PronunciationOverrides.merging(
            global: ["docker": "ˈdɒkə"],
            book: ["docker": "ˈdɑkər"])
        #expect(ovr.entries["docker"] == "ˈdɑkər") // book overrides global
    }

    @Test func emptyOverridesAreNoOp() throws {
        let ovr = PronunciationOverrides(entries: [:])
        let original = "Nothing changes here."
        #expect(ovr.apply(to: original) == original)
    }

    @Test func alreadyLinkedTextIsNotDoubleWrapped() throws {
        // If the source already contains a Misaki link, don't re-wrap.
        let ovr = PronunciationOverrides(entries: ["Kokoro": "kˈOkəɹO"])
        let out = ovr.apply(to: "[Kokoro](/kˈOkəɹO/) models")
        #expect(out == "[Kokoro](/kˈOkəɹO/) models") // unchanged
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests 2>&1 | grep -E "error:" | head`
Expected: `cannot find 'PronunciationOverrides' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure text rewriter that injects user-supplied pronunciations into Misaki's
/// native `[word](/ipa/)` link syntax before G2P. Misaki parses such links with
/// `rating: 5` (highest confidence), bypassing both the lexicon and the (removed)
/// BART fallback — so an override always wins.
///
/// Case-insensitive whole-word match; substring matches are rejected ("use" must
/// not match inside "user"). Per-book entries override global entries on conflict.
struct PronunciationOverrides {
    let entries: [String: String]

    /// Apply overrides to `text`, wrapping each matched whole word in link syntax.
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }
        // One combined regex alternation, case-insensitive, word-boundary guarded.
        // Escape regex metacharacters in keys and skip empty values.
        let escaped = entries.keys
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .sorted { $0.count > $1.count } // longest-first so "Postgres" beats "Post"
        guard !escaped.isEmpty else { return text }
        let pattern = "\\b(?:" + escaped.joined(separator: "|") + ")\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let nsText = text as NSString
        // Process matches right-to-left so index offsets stay valid.
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = re.matches(in: text, range: fullRange).reversed()
        var result = text
        for m in matches {
            guard let range = Range(m.range, in: result) else { continue }
            let matched = String(result[range])
            // Lowercased lookup (case-insensitive match).
            guard let ipa = entries.first(where: { $0.key.lowercased() == matched.lowercased() })?.value else {
                continue
            }
            // Skip if this word is already inside a link "[...](/.../)": look back
            // for an unbalanced "[". Cheap heuristic — Misaki links are rare in prose.
            if isInsideLink(result, at: range.lowerBound) { continue }
            result.replaceSubrange(range, with: "[\(matched)](/\(ipa)/)")
        }
        return result
    }

    /// True if `index` falls inside a `[...](/.../)` link's display text.
    private func isInsideLink(_ s: String, at index: String.Index) -> Bool {
        // Walk back to the nearest '[' that has no following ']' before `index`.
        var i = index
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == "]" { return false } // closed before us → not in a link
            if s[i] == "[" { return true } // open bracket → we're inside display text
        }
        return false
    }

    /// Merge two maps; `book` wins on key conflict.
    static func merging(global: [String: String], book: [String: String]) -> PronunciationOverrides {
        PronunciationOverrides(entries: global.merging(book) { _, b in b })
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-only FILTER=EchoTests/PronunciationOverridesTests 2>&1 | grep -E "Test case|passed|failed"`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/PronunciationOverrides.swift EchoTests/PronunciationOverridesTests.swift
git commit -m "feat(narration): PronunciationOverrides — pure text rewriter for user IPA"
```

### Task B2: PronunciationOverrideStore — persistence + observable model

The `@MainActor @Observable` store that owns the editable maps, persists JSON to Application Support, and vends bindings for the UI. Global map only for v1; per-book is stubbed (empty) so the merge seam is in place.

**Files:**
- Create: `EchoCore/Services/Narration/PronunciationOverrideStore.swift`
- Test: `EchoTests/PronunciationOverrideStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

@Suite struct PronunciationOverrideStoreTests {

    @Test func roundTripsEntriesThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "Kubernetes", ipa: "kuːbərˈnɛtɪs")

        // Re-load from the same directory → entry persists.
        let reloaded = PronunciationOverrideStore(directory: tmp)
        #expect(reloaded.entries["Kubernetes"] == "kuːbərˈnɛtɪs")
    }

    @Test func deleteRemovesEntry() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "docker", ipa: "ˈdɒkə")
        try store.remove(word: "docker")
        #expect(store.entries["docker"] == nil)
    }

    @Test func overridingMergesForG2P() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "redis", ipa: "ˈɹiːdɪs")
        let ovr = store.overrides() // used by NarrationService
        #expect(ovr.entries["redis"] == "ˈɹiːdɪs")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests 2>&1 | grep -E "error:" | head`
Expected: `cannot find 'PronunciationOverrideStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import os.log

    /// Owns the user's pronunciation-override dictionary and persists it to
    /// Application Support as JSON. v1 ships a single global map; the per-book
    /// seam (`overrides(forBookID:)`) returns empty so the merge code in
    /// `NarrationService` is in place for a later per-book follow-up.
    ///
    /// UI binds to this via `@Bindable`; `set`/`remove` mutate `entries` and
    /// write through atomically.
    @MainActor
    @Observable
    final class PronunciationOverrideStore {
        private(set) var entries: [String: String] = [:]
        private let fileURL: URL
        private let logger = Logger(category: "PronunciationOverrides")

        /// Production initializer: persists under the shared Narration directory.
        convenience init() {
            let dir = NarrationCache.directory()
                .appendingPathComponent("Pronunciations", isDirectory: true)
            self.init(directory: dir)
        }

        /// Test/overridable initializer: persists to `directory/global.json`.
        init(directory: URL) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("global.json")
            load()
        }

        func set(word: String, ipa: String) throws {
            entries[word] = ipa
            try persist()
        }

        func remove(word: String) throws {
            entries[word] = nil
            try persist()
        }

        /// The override map `NarrationService` applies before G2P. v1: global only.
        func overrides() -> PronunciationOverrides {
            PronunciationOverrides(entries: entries)
        }

        /// Per-book overrides — v1 returns empty (global map covers the common case;
        /// a character-name-per-book follow-up plugs in here).
        func overrides(forBookID bookID: String) -> PronunciationOverrides {
            PronunciationOverrides(entries: [:])
        }

        // MARK: - Private

        private func load() {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else { return }
            self.entries = decoded
        }

        private func persist() throws {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.entries.count, privacy: .public) pronunciation overrides.")
        }
    }
#endif
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-only FILTER=EchoTests/PronunciationOverrideStoreTests 2>&1 | grep -E "Test case|passed|failed"`
Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/PronunciationOverrideStore.swift EchoTests/PronunciationOverrideStoreTests.swift
git commit -m "feat(narration): PronunciationOverrideStore — persisted @Observable IPA map"
```

### Task B3: Wire overrides into the synthesis path

Thread the override map through `PipelineInputs.make` and `NarrationService` so it's applied after `TextNormalizer` and before `KokoroG2P`.

**Files:**
- Modify: `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`

- [ ] **Step 1: Read the current `PipelineInputs.make` signature**

Read `EchoCore/Services/Narration/KokoroFixedShapeEngine.swift` lines 34–52. The signature is `static func make(text: String, voice: VoiceID) throws -> PipelineInputs`.

- [ ] **Step 2: Add an `overrides` parameter and apply it before G2P**

Change the signature to accept an optional overrides map (default empty, so existing callers + tests stay valid), and apply it to the text before phonemizing:

```swift
        static func make(
            text: String,
            voice: VoiceID,
            overrides: PronunciationOverrides = PronunciationOverrides(entries: [:])
        ) throws -> PipelineInputs {
            let g2p = KokoroG2P()
            let vocab = try KokoroPhonemeVocab()
            let pack = try KokoroVoicePack(named: voice.rawValue)
            let overridden = overrides.apply(to: text)
            let phonemes = g2p.phonemes(for: overridden)
            let ids = vocab.ids(forPhonemes: phonemes)
            let refS = pack.refS(forPhonemeCount: phonemes.count)
            return PipelineInputs(
                ids: ids,
                attentionMask: [Int32](repeating: 1, count: ids.count),
                refS: refS)
        }
```

- [ ] **Step 3: Update `synthesize` to pass the overrides through**

In `KokoroFixedShapeEngine.synthesize` (around line 84), add an `overrides` parameter and forward it:

```swift
        func synthesize(
            _ text: String,
            voice: VoiceID,
            overrides: PronunciationOverrides = PronunciationOverrides(entries: [:])
        ) async throws -> TTSChunk {
            try await prepare()
            guard let pipeline else { throw NarrationError.engineUnavailable }
            let inputs = try Self.PipelineInputs.make(text: text, voice: voice, overrides: overrides)
            let result = try pipeline.synthesize(
                inputIds: inputs.ids,
                attentionMask: inputs.attentionMask,
                refS: inputs.refS,
                speed: 1.0)
            return TTSChunk(
                samples: result.audio,
                sampleRate: 24_000,
                duration: Double(result.audio.count) / 24_000)
        }
```

- [ ] **Step 4: Check whether `TTSEngine` protocol constrains the signature**

Read `EchoCore/Services/Narration/TTSEngine.swift`. If the protocol declares `func synthesize(_ text: String, voice: VoiceID) -> TTSChunk` (no overrides), the new default-valued parameter is compatible (defaults satisfy the protocol). Confirm `KokoroFixedShapeEngine` still conforms. If the protocol is strict, add `overrides` to the protocol signature with a default, and update `MockTTSEngine` (search `EchoTests` for it) to match.

- [ ] **Step 5: Update `NarrationService` to inject the store's overrides**

In `NarrationService`, locate the call site that does `engine.synthesize(subText, voice: ...)` inside the chapter-render loop (grep for `synthesize(` in `NarrationService.swift`). Pass the global overrides:

```swift
let overrides = await pronunciationStore.overrides()
// ...inside the per-chunk loop:
try await engine.synthesize(subText, voice: voice, overrides: overrides)
```

`NarrationService` should hold a `PronunciationOverrideStore` (inject via init, defaulting to `PronunciationOverrideStore()`). If `NarrationService` is an `@Observable`/actor, take the store on `init` and store it.

- [ ] **Step 6: Build iOS device + macOS**

Run: `xcodebuild -scheme Echo -destination 'generic/platform=iOS' -jobs 5 build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Run: `xcodebuild -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 7: Run the engine build-inputs test to confirm overrides flow through**

Run: `make test-only FILTER=EchoTests/KokoroFixedShapeEngineTests 2>&1 | grep -E "passed|failed"`
Expected: existing engine tests still pass (they use the default empty overrides).

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Services/Narration/KokoroFixedShapeEngine.swift EchoCore/Services/Narration/NarrationService.swift
git commit -m "feat(narration): apply pronunciation overrides before G2P"
```

### Task B4: PronunciationDictionaryView — the Settings UI

A SwiftUI list for adding/editing/deleting global overrides. Bound to `PronunciationOverrideStore` via `@Bindable`.

**Files:**
- Create: `EchoCore/UI/PronunciationDictionaryView.swift`

- [ ] **Step 1: Locate the existing Settings entry point to match conventions**

Run: `grep -rln "Settings\|@Bindable.*Store\|NavigationStack" EchoCore/UI Echo/UI --include="*.swift" | head`
Read the main Settings view to match its styling (section/list patterns, the `Tab` API, `foregroundStyle`, etc.). Follow `AGENTS.md` SwiftUI rules: `NavigationStack`, `Tab` API (not `tabItem`), `Button("...", systemImage:)`, no `fontWeight()`, no `foregroundColor()`.

- [ ] **Step 2: Write the view**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import SwiftUI

    /// Settings screen for the user's pronunciation-override dictionary. Each
    /// row is a word → IPA pair; the engine pronounces overridden words using
    /// the supplied IPA, bypassing the lexicon. Useful for proper nouns and
    /// technical terms (e.g. "Kubernetes" → "kuːbərˈnɛtɪs").
    struct PronunciationDictionaryView: View {
        @Bindable var store: PronunciationOverrideStore
        @State private var newWord: String = ""
        @State private var newIPA: String = ""
        @State private var editingWord: String?

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        ForEach(store.entries.sorted(by: { $0.key < $1.key }), id: \.key) { word, ipa in
                            HStack {
                                Text(word)
                                    .bold()
                                Spacer()
                                Text(ipa)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    try? store.remove(word: word)
                                }
                            }
                        }
                    } header: {
                        Text("Saved pronunciations")
                    } footer: {
                        Text("Words here are pronounced using the IPA you provide, overriding the built-in dictionary. Power-user tip: for books full of invented names, add the main characters here.")
                    }

                    Section {
                        HStack {
                            TextField("Word", text: $newWord)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("IPA", text: $newIPA)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Add", systemImage: "plus.circle.fill") {
                                addEntry()
                            }
                            .disabled(newWord.isEmpty || newIPA.isEmpty)
                        }
                    } header: {
                        Text("Add a pronunciation")
                    } footer: {
                        Text("IPA only — e.g. kuːbərˈnɛtɪs for Kubernetes. Stress marks: ˈ primary, ˌ secondary.")
                    }
                }
                .navigationTitle("Pronunciation")
            }
        }

        private func addEntry() {
            let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
            let ipa = newIPA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !ipa.isEmpty else { return }
            try? store.set(word: word, ipa: ipa)
            newWord = ""
            newIPA = ""
        }
    }
#endif
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `make build-tests 2>&1 | grep -E "error:|TEST BUILD SUCCEEDED|TEST BUILD FAILED"`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/UI/PronunciationDictionaryView.swift
git commit -m "feat(narration): PronunciationDictionaryView — Settings UI for overrides"
```

### Task B5: Add the Settings row

Surface the dictionary view behind a row in the existing Settings screen.

**Files:**
- Modify: the main Settings view (located in Task B4 Step 1)

- [ ] **Step 1: Read the Settings view to find where to insert the row**

Read the Settings view identified in Task B4 Step 1. Find an appropriate `Section` (likely a "Reading"/"Audio" section) and the `PronunciationOverrideStore` must be available — either created at the app root and passed via the environment, or created here.

- [ ] **Step 2: Ensure the store is reachable from Settings**

If the app uses an environment-injected store pattern (grep for `@Environment` + the existing stores), add `PronunciationOverrideStore` the same way. Otherwise, instantiate it in the Settings view's `@State`:
```swift
@State private var pronunciationStore = PronunciationOverrideStore()
```

- [ ] **Step 3: Add the navigation row**

```swift
NavigationLink("Pronunciation", systemImage: "character.book.closed") {
    PronunciationDictionaryView(store: pronunciationStore)
}
```
Place it in the appropriate `Section` (the audio/reading one). Match the surrounding rows' label style.

- [ ] **Step 4: Build + run the sim app to visually confirm**

Run: `make build-tests 2>&1 | tail -3` then launch the sim app from Xcode (or `xcrun simctl`) and navigate Settings → Pronunciation. Add "test" → "tɛst", confirm it appears, delete it.
Expected: the screen renders, add/delete work, the entry persists across app restart.

- [ ] **Step 5: Commit**

```bash
git add <settings-view-path>
git commit -m "feat(narration): Pronunciation row in Settings"
```

---

## Part C — Verification + docs

### Task C1: Full verification pass

- [ ] **Step 1: Run the entire sim test suite**

Run: `make test-only 2>&1 | tail -15`
Expected: all tests pass, including the previously-MLX-blocked `KokoroG2PTests`, `KokoroVoicePackTests`, `KokoroFixedShapeEngineTests`, plus the new `PronunciationOverridesTests`, `PronunciationOverrideStoreTests`, `LexiconOnlyG2PTests`.

- [ ] **Step 2: Build all three shipping targets**

Run:
```bash
xcodebuild -scheme Echo -destination 'generic/platform=iOS' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
xcodebuild -scheme 'Echo macOS' -destination 'platform=macOS' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
xcodebuild -scheme 'Echo Watch App' -destination 'generic/platform=watchOS' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```
Expected: all three `BUILD SUCCEEDED`.

- [ ] **Step 3: Confirm the binary shrank**

Compare the app size before (commit at end of Phase 4.2) vs after this plan. Expected: ~12–18 MB smaller (BART safetensors removed).

### Task C2: Doc-sync

- [ ] **Step 1: Update CODE_AUDIT.md / CHANGELOG**

Note: MLX dependency removed (lexicon-only G2P), sim tests unblocked, pronunciation-override feature added.

- [ ] **Step 2: Update the plan's parent doc**

The 2026-06-18 fixed-shape plan's "fast-follow: lexicon-only G2P to drop MLX" note is now satisfied — mark it done / point to this plan.

---

## Self-Review

**1. Spec coverage:**
- "Drop MLX" → Tasks A1 (stub), A2 (delete BART files), A3 (Package.swift), A4 (pbxproj), A5 (resources). ✓
- "Lexicon-only G2P doesn't crash on OOV" → A1's stub returns `unk`, A6 tests it. ✓
- "User pronunciations" → B1 (rewriter), B2 (store), B3 (wire-in), B4 (UI), B5 (Settings row). ✓
- "Sim tests unblocked" → A4 Step 10 is the explicit gate; C1 Step 1 confirms the suite. ✓
- "Nonfiction OOV closed" → B1's override mechanism is the supported answer; the merge seam (B2 `overrides(forBookID:)`) leaves room for per-book follow-up. ✓

**2. Placeholder scan:** No "TBD"/"implement later". The Settings-view path in B5 is intentionally left as "the main Settings view located in B4 Step 1" because I did not grep for it yet — the executing engineer resolves it via the B4 Step 1 grep. This is a discoverable path, not a placeholder. Every code block is complete.

**3. Type consistency:** `PronunciationOverrides.entries` `[String:String]`, `.apply(to:)`, `.merging(global:book:)` (static), used consistently in B1/B2/B3. `PronunciationOverrideStore.entries`, `.set(word:ipa:)`, `.remove(word:)`, `.overrides()`, `.overrides(forBookID:)` consistent across B2/B3/B4/B5. `PipelineInputs.make(text:voice:overrides:)` and `synthesize(_:voice:overrides:)` default-valued to keep the protocol + existing tests valid.
