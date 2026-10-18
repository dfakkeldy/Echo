# Narration — Enable All Kokoro Voices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

> **Status:** PLAN ONLY — no code changed in the introducing PR (related narration work in flight).

**Goal:** Ship the full Kokoro voice set (currently the pipeline is wired to a single voice, `af_heart`/"Ava") so users can choose any of the ~54 Kokoro voices.

**Architecture:** The narration engine is already fully voice-parameterized — the model takes the voice purely as a `style [1,256]` tensor and loads `KokoroVoicePack(named: voice.rawValue)` per voice. The single-voice restriction lives in **one place** (`VoiceCatalog.all`) plus a guarding test. Work = (1) a one-time Python converter producing per-voice `.f32`+`.rows` packs, (2) bundle them, (3) expand the catalog, (4) grouping + preview in the picker. Cache keys already include the voice id, so switching voices invalidates correctly.

**Tech Stack:** Swift, SwiftUI, onnxruntime, Python (one-time converter), Xcode `PBXFileSystemSynchronizedRootGroup` resource auto-inclusion, Swift Testing.

## Why only one voice today (root cause, verified)

- `VoiceCatalog.all` is hardcoded to a single `NarrationVoice(af_heart, "Ava", "US · warm", "voice_ava")` ([VoiceCatalog.swift:19-23](EchoCore/Services/Narration/VoiceCatalog.swift)). The doc comment (lines 12-18) blames FluidAudio's repo 404ing the other voices — **this justification is stale**: Echo no longer uses FluidAudio (it's on ONNX Runtime), and voices are bundled `.f32` files, not downloaded.
- The engine is voice-agnostic: it feeds the style vector as the `style` input ([OnnxKokoroEngine.swift:152-155, 162-165](EchoCore/Services/Narration/OnnxKokoroEngine.swift)) and loads the pack by name in `KokoroFrontEnd.encode`. **No model change, no re-download of the 163 MB model — a new voice = one ~510 KB `.f32` file + a `.rows` sidecar.**
- The voicepack format is documented: flat little-endian Float32 `[rows, 256]` reshaped from a `.f32` blob, with `rows` from a sidecar `.rows` text file; `af_heart.f32` = 522,240 bytes = 510×256×4 ([KokoroVoicePack.swift:7-54](EchoCore/Services/Narration/KokoroVoicePack.swift)).
- The picker already iterates `VoiceCatalog.all` ([VoicePickerView.swift:11](EchoCore/Views/Narration/VoicePickerView.swift)) and macOS settings does too ([MacSettingsView.swift:150](Echo macOS/Views/MacSettingsView.swift)) — so they scale to 54 entries for free; they just need grouping + preview.
- The blocking test: `VoiceCatalogTests.hasCuratedVoice()` asserts `VoiceCatalog.all.count == 1` ([VoiceCatalogTests.swift:7-13](EchoTests/VoiceCatalogTests.swift)) — this is the "trim to Ava" failure noted in project memory; it must be updated when voices are added.

## Decisions made while you slept (override freely)

- **Bundle all voices (~53 more `.f32`), do NOT download.** 54 × ~510 KB ≈ **~27 MB** added to the binary — an order of magnitude smaller than the model you already download, and it avoids network failure modes/cache UI. Files dropped into `EchoCore/Resources/` are auto-included via the synchronized group (no `pbxproj` edits).
- **Voice stays GLOBAL (one default in `UserDefaults` `narrationVoiceID`), not per-book.** The whole selection/persistence path is already global and correct; per-book would need a schema migration. The DB already records *which* voice rendered each chapter (`TrackRecord.narrationVoice`), so changing the global default never corrupts already-rendered books. Per-book override can be added later as a pure-additive enhancement.
- **Keep Ava (`af_heart`) as the default.**
- **Voice preview = synthesize-on-tap** via the live engine (no 54 bundled sample clips), falling back to a generic phrase. `sampleClipName` is currently unused dead-ish metadata.
- **Ship the full ~54 set** (vs a curated subset). Easy to trim later; full set is what "add all the voices" asks for.

## Open questions for Dan
1. Global vs per-book voice? (Recommend global now, per-book later.)
2. Keep Ava as default, or pick another now that there's choice?
3. Preview = synthesize-on-tap (recommended) vs bundling 54 clips?
4. Ship all ~54 or a curated A/B-graded subset (~10–15 ≈ 5–8 MB)?
5. OK to add a one-time Python converter under `Tools/`? (None exists; byte format documented in `KokoroVoicePack.swift`.)
6. Exclude `.f32` voice files from the **Widget** target membership? (It never narrates; saves ~27 MB in the widget bundle.)

## Global Constraints
- Branch target **`nightly`**. Feature change → **doc-sync** README/ARCHITECTURE + CHANGELOG; also fix the stale FluidAudio comment in `VoiceCatalog.swift:12-18`.
- Voicepack contract (verbatim): flat little-endian Float32, `[510, 256]`, sidecar `.rows` = `510`. Every converted pack MUST match or it throws `modelDownloadFailed` at render.
- Tests via `make build-tests` + `make test-only FILTER=…`. 16 GB machine constraints apply.
- Narration is iOS + macOS only. `VoiceCatalog`/`NarrationVoice`/`VoicePickerView` are shared (`EchoCore`); engine is `#if os(iOS) || os(macOS)`.

## File Structure
- `Tools/convert_kokoro_voices.py` — **create**: one-time converter, `hexgrad/Kokoro-82M/voices/*.pt` (or the onnx-community embeddings) → `<id>.f32` + `<id>.rows`.
- `EchoCore/Resources/<id>.f32` + `<id>.rows` — **create** (~53 pairs).
- `EchoCore/Services/Narration/VoiceCatalog.swift` — **modify**: full list + optional `accent`/`gender` fields for grouping.
- `EchoCore/Views/Narration/VoicePickerView.swift` — **modify**: sections + preview-on-tap.
- `Echo macOS/Views/MacSettingsView.swift` — **modify**: grouped picker.
- `EchoTests/VoiceCatalogTests.swift`, `EchoTests/KokoroVoicePackTests.swift` — **modify**: update count, parametrize over all voices.

---

### Task 1: One-time voice converter (Python)

**Files:** Create `Tools/convert_kokoro_voices.py`.

- [ ] **Step 1:** Write the converter: for each upstream voice tensor, write a flat little-endian fp32 `.f32` (shape `[510,256]`) + a `.rows` file containing `510`. Reuse the recorded `af_heart.f32` sha256 in `KokoroVoicePack.swift` as a round-trip fixture: re-converting `af_heart` MUST reproduce the byte-identical file.
- [ ] **Step 2:** Run it on `af_heart` only; diff against the existing `EchoCore/Resources/af_heart.f32` → must be byte-identical (`shasum -a 256`).
- [ ] **Step 3:** Generate all ~54 packs into a scratch dir; assert each is exactly 522,240 bytes and each `.rows` reads `510`.
- [ ] **Step 4: Commit** the script (not the generated files yet): `git commit -m "tools(narration): add Kokoro voice .pt→.f32 converter"`

### Task 2: Bundle the voice packs

**Files:** Create `EchoCore/Resources/<id>.f32` + `<id>.rows` for each new voice.

- [ ] **Step 1:** Copy the generated pairs into `EchoCore/Resources/` (auto-included via the synchronized group; no pbxproj edit).
- [ ] **Step 2 (optional):** add a Widget target-membership exception so the voice files aren't bundled into the widget (never narrates) — only if binary size matters there.
- [ ] **Step 3: Commit:** `git commit -m "assets(narration): bundle all Kokoro voice packs"`

### Task 3: Expand the catalog + grouping metadata

**Files:** Modify `EchoCore/Services/Narration/VoiceCatalog.swift`; Test `EchoTests/VoiceCatalogTests.swift`.

**Interfaces:**
- Produces: `VoiceCatalog.all` with ~54 `NarrationVoice` entries; optional `accent`/`gender` (or a grouping helper deriving them from the `af_/am_/bf_/bm_` id prefix) for the picker.

- [ ] **Step 1: Update the failing test first.** Change `hasCuratedVoice()` to assert the new count (e.g. `>= 50`) and that `af_heart` is present + default. Keep `allVoicesAreUnique()`.

```swift
@Test func catalogHasAllVoices() {
    #expect(VoiceCatalog.all.count >= 50)
    #expect(VoiceCatalog.all.contains { $0.id == VoiceID("af_heart") })
}
```

- [ ] **Step 2:** Run → fails (catalog still has 1).
- [ ] **Step 3:** Populate `VoiceCatalog.all` with all voices (display names + descriptors); replace the stale FluidAudio comment with the accurate ONNX/bundled rationale. Add grouping fields/helper.
- [ ] **Step 4:** Run → passes. Also run the new bundle-consistency test (Task 4) once it exists.
- [ ] **Step 5: Commit:** `git commit -m "feat(narration): expand VoiceCatalog to the full Kokoro voice set"`

### Task 4: Per-voice pack-load safety net

**Files:** Modify `EchoTests/KokoroVoicePackTests.swift`; add a catalog↔bundle consistency test (can live in `VoiceCatalogTests`).

- [ ] **Step 1: Failing test** — parametrize over **every** id in `VoiceCatalog.all`: each `.f32` loads, has 510 rows, returns 256-float rows, clamps correctly, and contains only finite values (guards a bad conversion). Plus: every catalog id has a bundled `<id>.f32` + `<id>.rows`.

```swift
@Test(arguments: VoiceCatalog.all)
func eachVoicePackLoadsAndIsFinite(_ voice: NarrationVoice) throws {
    let pack = try KokoroVoicePack(named: voice.id.rawValue)
    #expect(pack.rows == 510)
    let row = pack.refS(forPhonemeCount: 5)
    #expect(row.count == 256)
    #expect(row.allSatisfy { $0.isFinite })
}
```

- [ ] **Step 2:** Run → fails for any missing/malformed pack.
- [ ] **Step 3:** Fix conversion/bundling for any failures.
- [ ] **Step 4:** Run → all pass.
- [ ] **Step 5: Commit:** `git commit -m "test(narration): verify every bundled voice pack loads and is finite"`

### Task 5: Grouped voice picker + preview-on-tap (iOS)

**Files:** Modify `EchoCore/Views/Narration/VoicePickerView.swift`.

**Interfaces:**
- Consumes: `VoiceCatalog.all` grouping; the live engine for preview (synthesize a short phrase, e.g. "Hello, this is <name>.").
- Produces: sectioned list (American · Female / American · Male / British · Female / British · Male), tap-to-preview, accessible rows.

- [ ] **Step 1:** Add `Section`s grouped by accent+gender (from prefix/helper).
- [ ] **Step 2:** Add a preview affordance per row → synthesize-on-tap via the engine; cancel any in-flight preview when another row is tapped; show a tiny activity indicator. Fall back to a generic phrase.
- [ ] **Step 3:** Accessibility — label includes display name + descriptor + a "previews voice" hint; keep the existing `.isSelected` trait.
- [ ] **Step 4:** Manual check on device (Dan): 54 voices grouped, previews play, selection persists to `settings.narrationVoiceID`, "Start Narration" uses it.
- [ ] **Step 5: Commit:** `git commit -m "feat(narration): grouped voice picker with tap-to-preview (iOS)"`

### Task 6: macOS grouped picker (parity)

**Files:** Modify `Echo macOS/Views/MacSettingsView.swift:141-153`.

- [ ] **Step 1:** Group the flat narration `Picker` into `Section`s mirroring iOS (or adopt the shared `VoicePickerView`). Binds to the same global `settings.narrationVoiceID`, so adding voices already works — this is purely UX grouping.
- [ ] **Step 2:** Manual check (Dan): macOS shows all voices grouped; batch render uses the selected voice.
- [ ] **Step 3: Commit:** `git commit -m "feat(narration): grouped voice picker on macOS settings (parity)"`

### Task 7: Cache-invalidation regression guard

**Files:** Modify `EchoTests/NarrationCacheStoreTests.swift` / `EchoTests/NarrationFileNamingTests.swift`.

> Verified: the cache key already includes the voice — `chapterFileName` = `"<book>-ch<i>-<voice>-v<renderVersion>.m4a"` ([NarrationFileNaming.swift:32-34](EchoCore/Services/Narration/NarrationFileNaming.swift)); `startNarrationPlayback` sweeps stale-voice files before rendering ([PlayerModel+Narration.swift:62-71](EchoCore/ViewModels/PlayerModel+Narration.swift)). **Switching voice does NOT serve stale audio.** Adding voices does NOT require a `renderVersion` bump. This task just locks that in.

- [ ] **Step 1:** Add/confirm a test: two different voice ids → different filenames; switching A→B sweeps A's files for the book; a different book's files are untouched.
- [ ] **Step 2:** Run → pass.
- [ ] **Step 3: Commit:** `git commit -m "test(narration): guard voice-keyed cache invalidation across the full voice set"`

---

## Self-review notes
- **Spec coverage:** convert (T1) → bundle (T2) → catalog (T3) → safety (T4) → iOS UI (T5) → macOS UI (T6) → cache guard (T7). Covers "add all the voices" end to end.
- **No placeholders:** all file:line concrete; converter and tests have real code.
- **Type consistency:** `VoiceID`, `NarrationVoice`, `KokoroVoicePack(named:)`, `refS(forPhonemeCount:)`, `chapterFileName` all match the codebase.
- **Risk:** the only real risk is a malformed converted pack → caught by Task 4's finite/shape test before it can ship silent/garbage audio.
